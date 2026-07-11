defmodule DOM.Range.CloneContentsTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node
  alias DOM.Range

  # Serialize a fragment's children to a string for easy comparison.
  defp frag_html(fragment) do
    fragment
    |> Node.child_nodes()
    |> Enum.map_join("", &node_html/1)
  end

  defp node_html(%Node{type: :text} = n), do: Node.value(n)
  defp node_html(%Node{type: :element} = n), do: Element.outer_html(n)

  describe "clone_contents/1" do
    test "a collapsed range clones nothing" do
      doc = new_document("<p id='p'>hello</p>")
      p = DOM.query_selector(doc, "#p")
      range = Range.select_node_contents(Range.create_range(doc), p) |> Range.collapse(true)

      frag = Range.clone_contents(range)
      assert frag.type == :document_fragment
      assert Node.child_nodes(frag) == []
    end

    test "a range within one text node clones the substring" do
      doc = new_document("<p id='p'>hello world</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)
      range = Range.create_range(doc) |> Range.set_start(text, 6) |> Range.set_end(text, 11)

      frag = Range.clone_contents(range)
      assert frag_html(frag) == "world"
      # the source text is untouched (clone, not extract)
      assert Node.value(text) == "hello world"
    end

    test "a range over whole child elements clones them" do
      doc = new_document("<ul id='u'><li>a</li><li>b</li><li>c</li></ul>")
      u = DOM.query_selector(doc, "#u")
      # select children 1..3 (the 2nd and 3rd li)
      range = Range.create_range(doc) |> Range.set_start(u, 1) |> Range.set_end(u, 3)

      frag = Range.clone_contents(range)
      assert frag_html(frag) == "<li>b</li><li>c</li>"
      # source intact
      assert length(Node.child_nodes(u)) == 3
    end

    test "partial start + full middle + partial end across text boundaries" do
      doc = new_document("<div id='d'><p id='p1'>hello</p><p id='p2'>world</p></div>")
      p1 = DOM.query_selector(doc, "#p1")
      p2 = DOM.query_selector(doc, "#p2")
      [t1] = Node.child_nodes(p1)
      [t2] = Node.child_nodes(p2)

      # from char 2 of "hello" to char 3 of "world"
      range = Range.create_range(doc) |> Range.set_start(t1, 2) |> Range.set_end(t2, 3)

      frag = Range.clone_contents(range)
      # partial p1 keeps "llo", partial p2 keeps "wor"
      assert frag_html(frag) == "<p id=\"p1\">llo</p><p id=\"p2\">wor</p>"
      # source untouched
      assert Node.value(t1) == "hello"
      assert Node.value(t2) == "world"
    end
  end
end
