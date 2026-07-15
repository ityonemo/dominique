defmodule Integration.SlotchangeTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Event
  alias DOM.Node
  alias DOM.ShadowRoot

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#mutation-observers"

    # slotchange is a microtask: it fires AFTER the mutation (append returns first),
    # at the slot, bubbles:true composed:false; deduped within a task. We capture an
    # ordered log of markers + slotchange in the browser, and reproduce the same
    # observable sequence in Elixir (the slotchange fires during the checkpoint after
    # the enqueuing call, so in Elixir we drain the mailbox after each mutation).
    @js """
    return await page.evaluate(async () => {
      const doc = new DOMParser().parseFromString("<div id='h'></div>", "text/html");
      const host = doc.getElementById("h");
      const s = host.attachShadow({mode:"open"});
      s.innerHTML = "<slot name='x'></slot>";
      const slot = s.querySelector("slot");
      let seen = 0;
      slot.addEventListener("slotchange", e => {
        // assert flags/target hold in the browser too (throws would fail the oracle)
        if (e.target !== slot || e.bubbles !== true || e.composed !== false)
          throw new Error("unexpected slotchange shape");
        seen++;
      });

      const log = [];
      const add = (tag) => { const el = doc.createElement(tag); el.setAttribute("slot","x"); host.appendChild(el); };

      log.push("before");
      add("a");
      log.push("after-append-sync");     // slotchange NOT yet fired (it is a microtask)
      await Promise.resolve();
      log.push("fired=" + seen);         // one slotchange after the microtask

      // dedup: two appends in one task -> one slotchange
      seen = 0;
      add("b"); add("c");
      await Promise.resolve();
      log.push("dedup=" + seen);

      return log;
    });
    """

    test "slotchange timing, flags and dedup match the browser", %{js: expected} do
      # Reproduce the same observable sequence. slotchange fires during the checkpoint
      # after the enqueuing call replies, so we drain the mailbox to observe it.
      doc = DOM.new("<div id='h'></div>")
      host = DOM.query_selector(doc, "#h")
      shadow = Element.attach_shadow(host, :open)
      ShadowRoot.set_inner_html(shadow, "<slot name='x'></slot>")
      [slot] = Node.child_nodes(shadow)

      parent = self()

      Node.add_event_listener(slot, "slotchange", fn %Event{} = e ->
        send(parent, {:sc, e.target.node_id == slot.node_id, e.bubbles, e.composed})
      end)

      drain(50)

      add = fn tag ->
        el = DOM.create_element(doc, tag)
        Element.set_attribute(el, "slot", "x")
        Node.append_child(host, el)
      end

      log = ["before"]
      add.("a")
      log = log ++ ["after-append-sync"]
      fired = drain(50)
      log = log ++ ["fired=#{length(fired)}"]

      # dedup: two appends in ONE task (the browser's two synchronous appends are one
      # task; in Elixir a single server task = one DOM.lambda) -> one slotchange.
      DOM.lambda(doc.server, fn ->
        add.("b")
        add.("c")
      end)

      dedup = drain(50)
      log = log ++ ["dedup=#{length(dedup)}"]

      # the browser log (marker order + counts) must match ours
      assert log == expected

      # and our slotchange targeted the slot with the right flags (bubbles, ~composed)
      assert [{:sc, true, true, false}] = fired
    end

    defp drain(timeout, acc \\ []) do
      receive do
        msg -> drain(timeout, [msg | acc])
      after
        timeout -> Enum.reverse(acc)
      end
    end
  end
end
