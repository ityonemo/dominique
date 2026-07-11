defmodule DOM.Shadow.SlotTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node
  alias DOM.ShadowRoot
  alias DOM.Slot

  # Build: <host id> with light children, and a shadow tree of <slot>s.
  defp setup_host(light, shadow_html) do
    doc = new_document("<div id='host'>#{light}</div>")
    host = DOM.query_selector(doc, "#host")
    shadow = Element.attach_shadow(host, :open)
    ShadowRoot.set_inner_html(shadow, shadow_html)
    {doc, host, shadow}
  end

  defp names(nodes), do: Enum.map(nodes, &Node.node_name/1)

  describe "assigned_nodes / assigned_elements" do
    test "the default slot receives light children without a slot attribute" do
      {_doc, _host, shadow} =
        setup_host("<a>1</a><b>2</b>", "<slot></slot>")

      [slot] = Node.child_nodes(shadow)
      assert names(Slot.assigned_nodes(slot)) == ["a", "b"]
    end

    test "a named slot receives light children whose slot attribute matches" do
      {_doc, _host, shadow} =
        setup_host(
          "<a slot='x'>1</a><b>2</b><c slot='x'>3</c>",
          "<slot name='x'></slot><slot></slot>"
        )

      [named, default] = Node.child_nodes(shadow)
      assert names(Slot.assigned_nodes(named)) == ["a", "c"]
      assert names(Slot.assigned_nodes(default)) == ["b"]
    end

    test "assignment is in host light-tree order" do
      {_doc, _host, shadow} =
        setup_host("<c slot='s'>3</c><a slot='s'>1</a>", "<slot name='s'></slot>")

      [slot] = Node.child_nodes(shadow)
      # host order is c then a
      assert names(Slot.assigned_nodes(slot)) == ["c", "a"]
    end

    test "an unassigned slot has no assigned nodes" do
      {_doc, _host, shadow} =
        setup_host("<a slot='x'>1</a>", "<slot name='y'></slot>")

      [slot] = Node.child_nodes(shadow)
      assert Slot.assigned_nodes(slot) == []
    end

    test "assigned_elements filters to element nodes" do
      {_doc, _host, shadow} = setup_host("text<a>1</a>", "<slot></slot>")
      [slot] = Node.child_nodes(shadow)
      # text + <a> assigned, but assigned_elements is just the element
      assert names(Slot.assigned_elements(slot)) == ["a"]
    end
  end

  describe "assigned_slot" do
    test "returns the slot a light child is assigned to" do
      {_doc, host, shadow} = setup_host("<a slot='x'>1</a>", "<slot name='x'></slot>")
      [a] = Node.child_nodes(host)
      [slot] = Node.child_nodes(shadow)

      assert Node.assigned_slot(a).node_id == slot.node_id
    end

    test "returns nil for an unassigned light child" do
      {_doc, host, _shadow} = setup_host("<a slot='y'>1</a>", "<slot name='x'></slot>")
      [a] = Node.child_nodes(host)
      assert Node.assigned_slot(a) == nil
    end

    test "returns nil for a node whose parent is not a shadow host" do
      doc = new_document("<div id='d'><a>1</a></div>")
      [a] = Node.child_nodes(DOM.query_selector(doc, "#d"))
      assert Node.assigned_slot(a) == nil
    end
  end

  describe "assignment is maintained on mutation" do
    test "adding a light child updates assignment" do
      {doc, host, shadow} = setup_host("<a slot='x'>1</a>", "<slot name='x'></slot>")
      [slot] = Node.child_nodes(shadow)
      assert names(Slot.assigned_nodes(slot)) == ["a"]

      b = DOM.create_element(doc, "b")
      Element.set_attribute(b, "slot", "x")
      Node.append_child(host, b)

      assert names(Slot.assigned_nodes(slot)) == ["a", "b"]
    end

    test "removing a light child updates assignment" do
      {_doc, host, shadow} =
        setup_host("<a slot='x'>1</a><b slot='x'>2</b>", "<slot name='x'></slot>")

      [slot] = Node.child_nodes(shadow)
      [a, _b] = Node.child_nodes(host)

      Node.remove_child(host, a)
      assert names(Slot.assigned_nodes(slot)) == ["b"]
    end

    test "changing a light child's slot attribute re-slots it" do
      {doc, _host, shadow} =
        setup_host("<a slot='x'>1</a>", "<slot name='x'></slot><slot name='y'></slot>")

      [sx, sy] = Node.child_nodes(shadow)
      [a] = Node.child_nodes(DOM.query_selector(doc, "#host"))
      assert names(Slot.assigned_nodes(sx)) == ["a"]

      Element.set_attribute(a, "slot", "y")
      assert Slot.assigned_nodes(sx) == []
      assert names(Slot.assigned_nodes(sy)) == ["a"]
    end
  end
end
