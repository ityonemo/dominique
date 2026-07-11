defmodule DOM.Range.InsertSurroundTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node
  alias DOM.Range

  describe "insert_node/2" do
    test "inserts a node at a child-index boundary" do
      doc = new_document("<ul id='u'><li id='a'>a</li><li id='b'>b</li></ul>")
      u = DOM.query_selector(doc, "#u")
      range = Range.create_range(doc) |> Range.set_start(u, 1) |> Range.set_end(u, 1)

      new_li = DOM.create_element(doc, "li")
      Element.set_attribute(new_li, "id", "x")
      Range.insert_node(range, new_li)

      assert Enum.map(Node.child_nodes(u), &Element.get_attribute(&1, "id")) == ["a", "x", "b"]
    end

    test "inserts a node mid-text, splitting the text node" do
      doc = new_document("<p id='p'>hello</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)
      range = Range.create_range(doc) |> Range.set_start(text, 2) |> Range.set_end(text, 2)

      span = DOM.create_element(doc, "span")
      Range.insert_node(range, span)

      # p's children: "he", <span>, "llo"
      values = Enum.map(Node.child_nodes(p), fn n -> Node.value(n) || Node.node_name(n) end)
      assert values == ["he", "span", "llo"]
    end
  end

  describe "surround_contents/2" do
    test "wraps the range's contents in the given element" do
      doc = new_document("<p id='p'>hello world</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)
      range = Range.create_range(doc) |> Range.set_start(text, 6) |> Range.set_end(text, 11)

      mark = DOM.create_element(doc, "mark")
      Range.surround_contents(range, mark)

      # "hello " then <mark>world</mark>
      assert Element.inner_html(p) == "hello <mark>world</mark>"
    end

    test "raises InvalidStateError when the range partially selects a non-Text node" do
      doc = new_document("<div id='d'><p id='p1'>a</p><p id='p2'>b</p></div>")
      p1 = DOM.query_selector(doc, "#p1")
      p2 = DOM.query_selector(doc, "#p2")
      [t1] = Node.child_nodes(p1)
      [t2] = Node.child_nodes(p2)
      # partially selects p1 and p2 (non-Text) -> invalid
      range = Range.create_range(doc) |> Range.set_start(t1, 0) |> Range.set_end(t2, 1)

      wrapper = DOM.create_element(doc, "span")
      assert_raise DOM.InvalidStateError, fn -> Range.surround_contents(range, wrapper) end
    end
  end
end
