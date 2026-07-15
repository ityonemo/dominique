defmodule DOM.Shadow.SlotAssignTest do
  use DOM.Case, async: true

  # Imperative slotting: slot.assign(...nodes) in a manual-mode shadow root. Manual
  # mode turns OFF attribute-based auto-slotting; a slot has no assigned nodes until
  # assign() is called. assign REPLACES; assign() clears; only host light-DOM children
  # actually assign. Browser-verified in the slot-assign-semantics memory.

  alias DOM.Element
  alias DOM.Node
  alias DOM.ShadowRoot
  alias DOM.Slot

  defp names(nodes), do: Enum.map(nodes, &Node.node_name/1)

  defp manual_host(light) do
    doc = new_document("<div id='host'>#{light}</div>")
    host = DOM.query_selector(doc, "#host")
    shadow = Element.attach_shadow(host, :open, slot_assignment: :manual)
    ShadowRoot.set_inner_html(shadow, "<slot></slot>")
    [slot] = Node.child_nodes(shadow)
    {doc, host, slot}
  end

  test "manual mode does not auto-slot (attributes are ignored)" do
    {_doc, _host, slot} = manual_host("<a slot='x'>1</a>")
    # even a matching slot= attribute assigns nothing in manual mode
    assert Slot.assigned_nodes(slot) == []
  end

  test "assign() assigns the given host children in order" do
    {doc, _host, slot} = manual_host("<a>1</a><b>2</b><c>3</c>")
    a = DOM.query_selector(doc, "a")
    c = DOM.query_selector(doc, "c")

    Slot.assign(slot, [a, c])
    assert names(Slot.assigned_nodes(slot)) == ["a", "c"]
  end

  test "assign() replaces the previous assignment" do
    {doc, _host, slot} = manual_host("<a>1</a><b>2</b><c>3</c>")
    a = DOM.query_selector(doc, "a")
    c = DOM.query_selector(doc, "c")

    Slot.assign(slot, [a, c])
    Slot.assign(slot, [c])
    assert names(Slot.assigned_nodes(slot)) == ["c"]
  end

  test "assign() with no nodes clears the assignment" do
    {doc, _host, slot} = manual_host("<a>1</a>")
    a = DOM.query_selector(doc, "a")

    Slot.assign(slot, [a])
    assert names(Slot.assigned_nodes(slot)) == ["a"]
    Slot.assign(slot, [])
    assert Slot.assigned_nodes(slot) == []
  end

  test "a node that is not a host child is not actually assigned" do
    {doc, _host, slot} = manual_host("<a>1</a>")
    a = DOM.query_selector(doc, "a")
    stray = DOM.create_element(doc, "z")

    Slot.assign(slot, [a, stray])
    # stray isn't a light-DOM child of the host, so only a is assigned
    assert names(Slot.assigned_nodes(slot)) == ["a"]
  end

  test "assign() fires slotchange as a microtask" do
    {doc, _host, slot} = manual_host("<a>1</a>")
    a = DOM.query_selector(doc, "a")
    parent = self()
    Node.add_event_listener(slot, "slotchange", fn _ -> send(parent, :slotchange) end)

    Slot.assign(slot, [a])
    # fired asynchronously during the checkpoint after the call
    assert_receive :slotchange, 200
  end

  test "named (default) mode is unaffected: attribute auto-slotting still works" do
    doc = new_document("<div id='host'><a slot='x'>1</a></div>")
    host = DOM.query_selector(doc, "#host")
    shadow = Element.attach_shadow(host, :open)
    ShadowRoot.set_inner_html(shadow, "<slot name='x'></slot>")
    [slot] = Node.child_nodes(shadow)

    assert names(Slot.assigned_nodes(slot)) == ["a"]
  end
end
