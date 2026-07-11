defmodule DOM.Range.ExtractContentsTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node
  alias DOM.Range

  defp frag_html(fragment) do
    fragment |> Node.child_nodes() |> Enum.map_join("", &node_html/1)
  end

  defp node_html(%Node{type: :text} = n), do: Node.value(n)
  defp node_html(%Node{type: :element} = n), do: Element.outer_html(n)

  describe "extract_contents/1" do
    test "a range within one text node extracts the substring and truncates the source" do
      doc = new_document("<p id='p'>hello world</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)
      range = Range.create_range(doc) |> Range.set_start(text, 6) |> Range.set_end(text, 11)

      frag = Range.extract_contents(range)
      assert frag_html(frag) == "world"
      # source loses "world"
      assert Node.value(text) == "hello "
      # range collapses to the start
      assert Range.collapsed?(range)
    end

    test "extracting whole child elements removes them from the source" do
      doc = new_document("<ul id='u'><li>a</li><li>b</li><li>c</li></ul>")
      u = DOM.query_selector(doc, "#u")
      range = Range.create_range(doc) |> Range.set_start(u, 1) |> Range.set_end(u, 3)

      frag = Range.extract_contents(range)
      assert frag_html(frag) == "<li>b</li><li>c</li>"
      # source keeps only the first li
      assert Enum.map(Node.child_nodes(u), &Node.value(Enum.at(Node.child_nodes(&1), 0))) == ["a"]
      assert Range.collapsed?(range)
    end

    test "partial start + partial end across text boundaries" do
      doc = new_document("<div id='d'><p id='p1'>hello</p><p id='p2'>world</p></div>")
      p1 = DOM.query_selector(doc, "#p1")
      p2 = DOM.query_selector(doc, "#p2")
      [t1] = Node.child_nodes(p1)
      [t2] = Node.child_nodes(p2)
      range = Range.create_range(doc) |> Range.set_start(t1, 2) |> Range.set_end(t2, 3)

      frag = Range.extract_contents(range)
      assert frag_html(frag) == "<p id=\"p1\">llo</p><p id=\"p2\">wor</p>"
      # source: p1 keeps "he", p2 keeps "ld"
      assert Node.value(t1) == "he"
      assert Node.value(t2) == "ld"
      assert Range.collapsed?(range)
    end
  end

  describe "delete_contents/1" do
    test "removes the selected content, returns nothing, collapses the range" do
      doc = new_document("<p id='p'>hello world</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)
      range = Range.create_range(doc) |> Range.set_start(text, 5) |> Range.set_end(text, 11)

      assert Range.delete_contents(range) == :ok
      assert Node.value(text) == "hello"
      assert Range.collapsed?(range)
    end

    test "deletes whole children" do
      doc = new_document("<ul id='u'><li>a</li><li>b</li><li>c</li></ul>")
      u = DOM.query_selector(doc, "#u")
      range = Range.create_range(doc) |> Range.set_start(u, 0) |> Range.set_end(u, 2)

      Range.delete_contents(range)
      assert length(Node.child_nodes(u)) == 1
    end
  end
end
