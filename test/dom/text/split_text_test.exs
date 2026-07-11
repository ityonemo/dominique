defmodule DOM.Text.SplitTextTest do
  use DOM.Case, async: true

  alias DOM.Node
  alias DOM.Range
  alias DOM.Text

  describe "split_text/2" do
    test "splits a text node into two at the offset; returns the new sibling" do
      doc = new_document("<p id='p'>hello world</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)

      new_node = Text.split_text(text, 5)

      assert Node.value(text) == "hello"
      assert Node.value(new_node) == " world"
      assert new_node.type == :text
      # p now has two text children, in order
      assert Enum.map(Node.child_nodes(p), &Node.value/1) == ["hello", " world"]
      assert Node.parent_node(new_node).node_id == p.node_id
    end

    test "the new node is inserted immediately after the original, before later siblings" do
      doc = new_document("<p id='p'>ab<span id='s'>x</span></p>")
      p = DOM.query_selector(doc, "#p")
      [text | _] = Node.child_nodes(p)

      Text.split_text(text, 1)

      # order: "a", "b", <span>
      values = Enum.map(Node.child_nodes(p), fn n -> Node.value(n) || Node.node_name(n) end)
      assert values == ["a", "b", "span"]
    end

    test "offset 0 leaves an empty original and a full new node" do
      doc = new_document("<p id='p'>abc</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)

      new_node = Text.split_text(text, 0)
      assert Node.value(text) == ""
      assert Node.value(new_node) == "abc"
    end

    test "offset past the length raises IndexSizeError" do
      doc = new_document("<p id='p'>ab</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)

      assert_raise DOM.IndexSizeError, fn -> Text.split_text(text, 3) end
    end

    test "split_text on a non-text node raises" do
      doc = new_document("<p id='p'>x</p>")
      p = DOM.query_selector(doc, "#p")
      assert_raise FunctionClauseError, fn -> Text.split_text(p, 0) end
    end

    test "a range boundary past the split point moves into the new node (spec)" do
      doc = new_document("<p id='p'>hello world</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)

      # boundary at char 8 (inside " world", which is offset 3 of the new node)
      range = Range.create_range(doc) |> Range.set_start(text, 8) |> Range.set_end(text, 8)

      new_node = Text.split_text(text, 5)

      assert Range.start_container(range).node_id == new_node.node_id
      assert Range.start_offset(range) == 3
    end
  end
end
