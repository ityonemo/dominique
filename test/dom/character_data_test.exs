defmodule DOM.CharacterDataTest do
  use DOM.Case, async: true

  # T6: CharacterData string edits (guarded on :text/:comment) + Text.whole_text.
  # replaceData is the primitive; append/insert/delete express via it. Edits adjust
  # live Range boundaries in the node.

  alias DOM.CharacterData, as: CD
  alias DOM.Node

  defp text(value) do
    doc = new_document("<p id='p'>#{value}</p>")
    p = DOM.query_selector(doc, "#p")
    [t] = Node.child_nodes(p)
    {doc, t}
  end

  describe "reads" do
    test "length and substring_data" do
      {_doc, t} = text("hello")
      assert CD.length(t) == 5
      assert CD.substring_data(t, 1, 3) == "ell"
      assert CD.substring_data(t, 3, 100) == "lo"
    end

    test "substring_data raises IndexSizeError when offset exceeds length" do
      {_doc, t} = text("hi")
      assert_raise DOM.IndexSizeError, fn -> CD.substring_data(t, 5, 1) end
    end
  end

  describe "mutations" do
    test "append_data / insert_data / delete_data / replace_data" do
      {_doc, t} = text("hello")

      CD.append_data(t, " world")
      assert Node.value(t) == "hello world"

      CD.insert_data(t, 0, ">> ")
      assert Node.value(t) == ">> hello world"

      CD.delete_data(t, 0, 3)
      assert Node.value(t) == "hello world"

      CD.replace_data(t, 0, 5, "HELLO")
      assert Node.value(t) == "HELLO world"
    end
  end

  describe "live range adjustment" do
    test "replace_data shifts a boundary after the edited region" do
      {doc, t} = text("hello world")
      range = DOM.Range.create_range(doc)
      range = DOM.Range.set_start(range, t, 6)
      range = DOM.Range.set_end(range, t, 11)
      # range selects "world"

      # replace "hello" (0..5) with "HI" -> content shifts left by 3
      CD.replace_data(t, 0, 5, "HI")
      assert Node.value(t) == "HI world"
      assert DOM.Range.start_offset(range) == 3
      assert DOM.Range.end_offset(range) == 8
    end

    test "a boundary inside the replaced region clamps to the offset" do
      {doc, t} = text("hello")
      range = DOM.Range.create_range(doc)
      range = DOM.Range.set_start(range, t, 1)
      range = DOM.Range.set_end(range, t, 4)

      CD.replace_data(t, 0, 5, "X")
      assert DOM.Range.start_offset(range) == 0
      assert DOM.Range.end_offset(range) == 0
    end
  end

  describe "Text.whole_text" do
    test "concatenates the contiguous text run, stopping at element barriers" do
      doc = new_document("<p id='p'></p>")
      p = DOM.query_selector(doc, "#p")
      Node.append(p, ["foo", "bar"])
      b = DOM.create_element(doc, "b")
      Node.append(p, [b, "baz"])

      # children: text"foo", text"bar", <b>, text"baz" (append does not normalize)
      [foo, _bar, _b, baz] = Node.child_nodes(p)
      assert DOM.Text.whole_text(foo) == "foobar"
      assert DOM.Text.whole_text(baz) == "baz"
    end
  end
end
