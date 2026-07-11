defmodule DOM.Node.ParentChildMixinTest do
  use DOM.Case, async: true

  # T1: ParentNode / ChildNode / sibling-element mixins. Element-filtered traversal
  # reads + the convenience mutators (remove/before/after/replace_with/prepend/
  # append), which accept nodes and strings (strings -> Text nodes, per spec).

  alias DOM.Element
  alias DOM.Node

  defp ids(nodes), do: Enum.map(nodes, &Element.get_attribute(&1, "id"))

  describe "element traversal reads" do
    setup do
      doc = new_document("<ul id='u'>x<li id='a'></li>y<li id='b'></li><li id='c'></li>z</ul>")
      %{doc: doc, u: DOM.query_selector(doc, "#u")}
    end

    test "children returns only element children, in order", %{u: u} do
      assert ids(Node.children(u)) == ["a", "b", "c"]
    end

    test "first/last_element_child skip text nodes", %{u: u} do
      assert Element.get_attribute(Node.first_element_child(u), "id") == "a"
      assert Element.get_attribute(Node.last_element_child(u), "id") == "c"
    end

    test "child_element_count counts only elements", %{u: u} do
      assert Node.child_element_count(u) == 3
    end

    test "previous/next_element_sibling skip text nodes", %{doc: doc} do
      b = DOM.query_selector(doc, "#b")
      assert Element.get_attribute(Node.previous_element_sibling(b), "id") == "a"
      assert Element.get_attribute(Node.next_element_sibling(b), "id") == "c"
    end

    test "element-child reads are empty/nil at the edges", %{doc: doc} do
      a = DOM.query_selector(doc, "#a")
      c = DOM.query_selector(doc, "#c")
      assert Node.previous_element_sibling(a) == nil
      assert Node.next_element_sibling(c) == nil
      assert Node.children(a) == []
      assert Node.child_element_count(a) == 0
    end
  end

  describe "ChildNode mutators" do
    test "remove detaches the node from its parent" do
      doc = new_document("<div id='p'><span id='a'></span><span id='b'></span></div>")
      p = DOM.query_selector(doc, "#p")
      a = DOM.query_selector(doc, "#a")

      Node.remove(a)
      assert ids(Node.children(p)) == ["b"]
      assert Node.parent_node(a) == nil
    end

    test "before / after insert siblings (nodes and strings)" do
      doc = new_document("<div id='p'><span id='b'></span></div>")
      p = DOM.query_selector(doc, "#p")
      b = DOM.query_selector(doc, "#b")

      before_el = DOM.create_element(doc, "i")
      Element.set_attribute(before_el, "id", "before")
      Node.before(b, [before_el, "txt"])

      after_el = DOM.create_element(doc, "u")
      Element.set_attribute(after_el, "id", "after")
      Node.after(b, [after_el])

      assert ids(Node.children(p)) == ["before", "b", "after"]
      assert Node.text_content(p) == "txt"
    end

    test "replace_with swaps the node for the given nodes" do
      doc = new_document("<div id='p'><span id='old'></span></div>")
      p = DOM.query_selector(doc, "#p")
      old = DOM.query_selector(doc, "#old")

      a = DOM.create_element(doc, "a")
      Element.set_attribute(a, "id", "new")
      Node.replace_with(old, [a])

      assert ids(Node.children(p)) == ["new"]
    end
  end

  describe "ParentNode mutators" do
    test "append adds children at the end (nodes and strings)" do
      doc = new_document("<div id='p'><span id='a'></span></div>")
      p = DOM.query_selector(doc, "#p")

      b = DOM.create_element(doc, "span")
      Element.set_attribute(b, "id", "b")
      Node.append(p, [b, "tail"])

      assert ids(Node.children(p)) == ["a", "b"]
      assert Node.text_content(p) == "tail"
    end

    test "prepend adds children at the start" do
      doc = new_document("<div id='p'><span id='a'></span></div>")
      p = DOM.query_selector(doc, "#p")

      z = DOM.create_element(doc, "span")
      Element.set_attribute(z, "id", "z")
      Node.prepend(p, [z])

      assert ids(Node.children(p)) == ["z", "a"]
    end
  end
end
