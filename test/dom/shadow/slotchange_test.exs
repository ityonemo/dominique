defmodule DOM.Shadow.SlotchangeTest do
  use DOM.Case, async: true

  # slotchange: fired (as a MICROTASK, after the mutation) at a <slot> whose
  # assigned-node set actually CHANGED. bubbles: true, composed: false, not
  # cancelable; deduped per task (a slot signaled N times in one task fires once).
  # Browser-verified semantics recorded in the slotchange-semantics memory.

  alias DOM.Element
  alias DOM.Event
  alias DOM.Node
  alias DOM.ShadowRoot

  defp setup_host(light, shadow_html) do
    doc = new_document("<div id='host'>#{light}</div>")
    host = DOM.query_selector(doc, "#host")
    shadow = Element.attach_shadow(host, :open)
    ShadowRoot.set_inner_html(shadow, shadow_html)
    {doc, host, shadow}
  end

  # Register a slotchange listener on `node` that reports `tag` to the test process,
  # tagged with the event's bubbles and composed flags.
  defp watch(node, tag) do
    parent = self()

    Node.add_event_listener(node, "slotchange", fn %Event{} = event ->
      send(parent, {tag, event.bubbles, event.composed})
    end)
  end

  describe "when it fires" do
    test "adding a matching light child fires slotchange at the slot, after the mutation" do
      {_doc, host, shadow} = setup_host("<a slot='x'>1</a>", "<slot name='x'></slot>")
      [slot] = Node.child_nodes(shadow)
      watch(slot, :changed)
      # drain the initial-assignment slotchange from set_inner_html/setup, if any
      flush()

      b = DOM.create_element(Node.owner_document(host), "b")
      Element.set_attribute(b, "slot", "x")

      # slotchange is a MICROTASK: it fires during the checkpoint that runs in a
      # separate handle_continue AFTER the append_child call replies. So we block on
      # the message (assert_receive) rather than assert_received — the same async
      # observation the microtask primitive tests use. bubbles: true, composed: false.
      Node.append_child(host, b)

      assert_receive {:changed, true, false}
    end

    test "removing the only assigned node fires slotchange (assignment lost)" do
      {_doc, host, shadow} = setup_host("<a slot='x'>1</a>", "<slot name='x'></slot>")
      [slot] = Node.child_nodes(shadow)
      a = DOM.query_selector(Node.owner_document(host), "a")
      watch(slot, :changed)
      flush()

      Node.remove_child(host, a)

      assert_receive {:changed, true, false}
    end

    test "a mutation that changes no assignment fires nothing" do
      {_doc, host, shadow} = setup_host("", "<slot name='x'></slot>")
      [slot] = Node.child_nodes(shadow)
      watch(slot, :changed)
      flush()

      # a non-matching child (no slot='x') does not change the named slot's set
      p = DOM.create_element(Node.owner_document(host), "p")
      Node.append_child(host, p)

      refute_receive {:changed, _, _}
    end
  end

  describe "dedup (per task)" do
    test "each top-level change is its own task and fires slotchange" do
      {_doc, host, shadow} = setup_host("", "<slot name='x'></slot>")
      [slot] = Node.child_nodes(shadow)
      watch(slot, :sc)
      flush()

      # Two SEPARATE top-level appends = two tasks = two checkpoints = two
      # slotchanges (dedup is within one task, not across tasks).
      for tag <- ["a", "b"] do
        el = DOM.create_element(Node.owner_document(host), tag)
        Element.set_attribute(el, "slot", "x")
        Node.append_child(host, el)
      end

      assert drain_count() == 2
    end

    test "two changes to the same slot within one task (re-entrant) fire once" do
      {doc, host, shadow} = setup_host("", "<slot name='x'></slot>")
      [slot] = Node.child_nodes(shadow)
      watch(slot, :sc)
      flush()

      # Run two assignment-changing mutations inside ONE server task (DOM.lambda),
      # so both signals land in the same checkpoint — dedup fires slotchange once.
      DOM.lambda(doc.server, fn ->
        a = DOM.create_element(doc, "a")
        Element.set_attribute(a, "slot", "x")
        Node.append_child(host, a)
        b = DOM.create_element(doc, "b")
        Element.set_attribute(b, "slot", "x")
        Node.append_child(host, b)
      end)

      assert drain_count() == 1
    end
  end

  # helpers -----------------------------------------------------------------

  # Drain any pending slotchange messages (e.g. an initial-assignment slotchange from
  # setup). Waits a beat on the first pass so an in-flight async slotchange arrives.
  defp flush do
    receive do
      _ -> flush()
    after
      20 -> :ok
    end
  end

  # Count slotchange messages that arrive within a short window (the async drain
  # runs just after the enqueuing call replies, so we must wait for delivery).
  defp drain_count(acc \\ 0) do
    receive do
      {:sc, _bubbles, _composed} -> drain_count(acc + 1)
    after
      50 -> acc
    end
  end
end
