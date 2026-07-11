defmodule Integration.EventTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Event
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#retargeting-algorithm"

    # Shadow dispatch: composed crosses the boundary to the host and retargets
    # event.target per node (host for light-DOM listeners, real target inside the
    # shadow); non-composed stops at the shadow root.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<section id='sec'><div id='host'></div></section>", "text/html");
      const host = doc.getElementById("host"), sec = doc.getElementById("sec");
      const s = host.attachShadow({ mode: "open" });
      s.innerHTML = "<span id='inner'>x</span>";
      const inner = s.getElementById("inner");

      const run = (composed) => {
        const fired = [];
        const nodes = [["inner", inner], ["shadow", s], ["host", host], ["sec", sec]];
        const regs = [];
        nodes.forEach(([label, n]) => {
          const h = (e) => fired.push(label + ":" + (e.target.id || e.target.nodeName));
          n.addEventListener("evt", h);
          regs.push([n, h]);
        });
        inner.dispatchEvent(new Event("evt", { bubbles: true, composed }));
        regs.forEach(([n, h]) => n.removeEventListener("evt", h));
        return fired;
      };

      return { composed: run(true), non_composed: run(false) };
    });
    """

    test "shadow retargeting + composed boundary match the browser", %{js: expected} do
      run = fn composed ->
        doc = DOM.new("<section id='sec'><div id='host'></div></section>")
        host = DOM.query_selector(doc, "#host")
        sec = DOM.query_selector(doc, "#sec")
        s = Element.attach_shadow(host, :open)
        DOM.ShadowRoot.set_inner_html(s, "<span id='inner'>x</span>")
        inner = DOM.query_selector(s, "#inner")
        me = self()

        # ev.target is always an ELEMENT here (inner or the retargeted host), so it
        # matches the browser's e.target.id.
        target_id = fn ev ->
          cond do
            ev.target.node_id == inner.node_id -> "inner"
            ev.target.node_id == host.node_id -> "host"
            true -> "?"
          end
        end

        for {label, node} <- [{"inner", inner}, {"shadow", s}, {"host", host}, {"sec", sec}] do
          Node.add_event_listener(node, "evt", fn ev ->
            send(me, label <> ":" <> target_id.(ev))
          end)
        end

        Node.dispatch_event(inner, Event.new("evt", bubbles: true, composed: composed))
        drain_order()
      end

      result = %{"composed" => run.(true), "non_composed" => run.(false)}
      assert result == expected
    end
  end

  playwright do
    @link "https://dom.spec.whatwg.org/#dispatching-events"

    # Target-phase dispatch: fire order, dispatchEvent's boolean return under
    # preventDefault (cancelable vs not), type filtering, and `once`.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString("<div id='d'></div>", "text/html");
      const d = doc.getElementById("d");
      const order = [];

      d.addEventListener("click", () => order.push("a"));
      d.addEventListener("click", () => order.push("b"));
      d.addEventListener("keydown", () => order.push("k"));

      const plain = d.dispatchEvent(new Event("click"));           // true
      const cancelHandler = (e) => e.preventDefault();

      d.addEventListener("cancelable", cancelHandler);
      const cancelled = d.dispatchEvent(new Event("cancelable", { cancelable: true }));   // false
      const notCancelable = d.dispatchEvent(new Event("cancelable"));                     // true (not cancelable)

      let onceCount = 0;
      d.addEventListener("boom", () => onceCount++, { once: true });
      d.dispatchEvent(new Event("boom"));
      d.dispatchEvent(new Event("boom"));

      return {
        order: order,          // ["a","b"] — keydown never fires on a click
        plain: plain,
        cancelled: cancelled,
        not_cancelable: notCancelable,
        once_count: onceCount
      };
    });
    """

    test "target-phase dispatch matches the browser", %{js: expected} do
      doc = DOM.new("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")
      me = self()

      Node.add_event_listener(d, "click", fn _ -> send(me, "a") end)
      Node.add_event_listener(d, "click", fn _ -> send(me, "b") end)
      Node.add_event_listener(d, "keydown", fn _ -> send(me, "k") end)

      plain = Node.dispatch_event(d, Event.new("click"))
      order = drain_order()

      Node.add_event_listener(d, "cancelable", fn ev -> Event.prevent_default(ev) end)
      cancelled = Node.dispatch_event(d, Event.new("cancelable", cancelable: true))
      not_cancelable = Node.dispatch_event(d, Event.new("cancelable"))

      {:ok, agent} = Agent.start_link(fn -> 0 end)
      Node.add_event_listener(d, "boom", fn _ -> Agent.update(agent, &(&1 + 1)) end, once: true)
      Node.dispatch_event(d, Event.new("boom"))
      Node.dispatch_event(d, Event.new("boom"))

      result = %{
        "order" => order,
        "plain" => plain,
        "cancelled" => cancelled,
        "not_cancelable" => not_cancelable,
        "once_count" => Agent.get(agent, & &1)
      }

      assert result == expected
    end
  end

  playwright do
    @link "https://dom.spec.whatwg.org/#dispatching-events"

    # Full capture -> target -> bubble across gp > p > t, with eventPhase recorded,
    # bubbles gating, and stopPropagation in the capture phase.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<a id='gp'><b id='p'><c id='t'></c></b></a>", "text/html");
      const gp = doc.getElementById("gp"), p = doc.getElementById("p"), t = doc.getElementById("t");

      const run = (bubbles, stopAt) => {
        const order = [];
        const mk = (label, phaseFlag) => (e) => {
          order.push(label + ":" + e.eventPhase);
          if (stopAt === label) e.stopPropagation();
        };
        const reg = [];
        const add = (node, label, capture) => {
          const h = mk(label, capture);
          node.addEventListener("x", h, { capture });
          reg.push([node, h, capture]);
        };
        add(gp, "gpC", true); add(p, "pC", true); add(t, "tC", true);
        add(t, "tB", false); add(p, "pB", false); add(gp, "gpB", false);
        t.dispatchEvent(new Event("x", { bubbles }));
        reg.forEach(([n, h, c]) => n.removeEventListener("x", h, c));
        return order;
      };

      return {
        bubbling: run(true, null),      // full capture+target+bubble
        non_bubbling: run(false, null), // capture + target only
        stopped: run(true, "pC")        // stop in capture at p
      };
    });
    """

    test "capture/target/bubble propagation matches the browser", %{js: expected} do
      run = fn bubbles, stop_at ->
        doc = DOM.new("<a id='gp'><b id='p'><c id='t'></c></b></a>")
        gp = DOM.query_selector(doc, "#gp")
        p = DOM.query_selector(doc, "#p")
        t = DOM.query_selector(doc, "#t")
        me = self()

        add = fn node, label, capture ->
          Node.add_event_listener(
            node,
            "x",
            fn ev ->
              send(me, "#{label}:#{ev.event_phase}")
              if stop_at == label, do: Event.stop_propagation(ev)
            end,
            capture: capture
          )
        end

        add.(gp, "gpC", true)
        add.(p, "pC", true)
        add.(t, "tC", true)
        add.(t, "tB", false)
        add.(p, "pB", false)
        add.(gp, "gpB", false)

        Node.dispatch_event(t, Event.new("x", bubbles: bubbles))
        drain_order()
      end

      result = %{
        "bubbling" => run.(true, nil),
        "non_bubbling" => run.(false, nil),
        "stopped" => run.(true, "pC")
      }

      assert result == expected
    end
  end

  # Collect fire-order tokens the listeners sent to us, in order.
  defp drain_order(acc \\ []) do
    receive do
      token when is_binary(token) -> drain_order([token | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
