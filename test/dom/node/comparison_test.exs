defmodule DOM.Node.ComparisonTest do
  use DOM.Case, async: true

  # T2: node comparison & inspection — contains, has_child_nodes, is_connected,
  # is_same_node, is_equal_node, compare_document_position.

  alias DOM.Node

  # DOCUMENT_POSITION_* bit constants
  @disconnected 1
  @preceding 2
  @following 4
  @contains 8
  @contained_by 16
  @impl_specific 32

  setup do
    doc = new_document("<div id='a'><span id='b'></span><span id='c'></span></div>")

    %{
      doc: doc,
      a: DOM.query_selector(doc, "#a"),
      b: DOM.query_selector(doc, "#b"),
      c: DOM.query_selector(doc, "#c")
    }
  end

  describe "contains" do
    test "an ancestor contains its descendants and itself", %{a: a, b: b} do
      assert Node.contains(a, b)
      assert Node.contains(a, a)
    end

    test "a descendant does not contain its ancestor; siblings don't contain", %{a: a, b: b, c: c} do
      refute Node.contains(b, a)
      refute Node.contains(b, c)
    end

    test "contains(node, nil) is false", %{a: a} do
      refute Node.contains(a, nil)
    end
  end

  describe "has_child_nodes / is_connected" do
    test "has_child_nodes reflects children", %{a: a, b: b} do
      assert Node.has_child_nodes(a)
      refute Node.has_child_nodes(b)
    end

    test "is_connected is true for in-document nodes, false for orphans", %{doc: doc, b: b} do
      assert Node.is_connected(b)
      orphan = DOM.create_element(doc, "i")
      refute Node.is_connected(orphan)
    end
  end

  describe "is_same_node / is_equal_node" do
    test "is_same_node compares identity", %{doc: doc, a: a} do
      also_a = DOM.query_selector(doc, "#a")
      assert Node.is_same_node(a, also_a)
      refute Node.is_same_node(a, DOM.query_selector(doc, "#b"))
      refute Node.is_same_node(a, nil)
    end

    test "is_equal_node is structural (name + attributes + value + children)" do
      doc = new_document("<div><p class='k'>hi</p><p class='k'>hi</p><p class='j'>hi</p></div>")
      [p1, p2, p3] = DOM.query_selector_all(doc, "p")

      assert Node.is_equal_node(p1, p2)
      # different attribute value -> not equal
      refute Node.is_equal_node(p1, p3)
      # same node is equal to itself
      assert Node.is_equal_node(p1, p1)
    end
  end

  describe "compare_document_position" do
    test "a contains b: b is CONTAINED_BY+FOLLOWING from a; a is CONTAINS+PRECEDING from b",
         %{a: a, b: b} do
      assert Node.compare_document_position(a, b) == @following + @contained_by
      assert Node.compare_document_position(b, a) == @preceding + @contains
    end

    test "siblings compare by document order", %{b: b, c: c} do
      assert Node.compare_document_position(b, c) == @following
      assert Node.compare_document_position(c, b) == @preceding
    end

    test "a node vs itself is 0", %{a: a} do
      assert Node.compare_document_position(a, a) == 0
    end

    test "disconnected nodes report DISCONNECTED + IMPLEMENTATION_SPECIFIC + a direction",
         %{doc: doc, a: a} do
      orphan = DOM.create_element(doc, "i")
      result = Node.compare_document_position(a, orphan)

      assert Bitwise.band(result, @disconnected) == @disconnected
      assert Bitwise.band(result, @impl_specific) == @impl_specific
      # exactly one of PRECEDING / FOLLOWING is set (a stable, arbitrary direction)
      assert Bitwise.band(result, @preceding) != 0 or Bitwise.band(result, @following) != 0
    end
  end
end
