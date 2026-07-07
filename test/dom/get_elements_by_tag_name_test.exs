defmodule DOM.GetElementsByTagNameTest do
  use ExUnit.Case, async: true

  alias DOM.Element
  alias DOM.Node

  setup do
    document = DOM.new()
    root = DOM.create_element(document, "root")
    a1 = DOM.create_element(document, "a")
    b = DOM.create_element(document, "b")
    a2 = DOM.create_element(document, "a")
    Node.append_child(document, root)
    Node.append_child(root, a1)
    Node.append_child(root, b)
    Node.append_child(b, a2)

    %{document: document, root: root, a1: a1, b: b, a2: a2}
  end

  test "returns matching descendants of the document in tree order", ctx do
    matches = DOM.get_elements_by_tag_name(ctx.document, "a")

    assert Enum.map(matches, & &1.id) == [ctx.a1.id, ctx.a2.id]
  end

  test "'*' returns every descendant element in tree order", ctx do
    matches = DOM.get_elements_by_tag_name(ctx.document, "*")

    assert Enum.map(matches, &Element.local_name/1) == ["root", "a", "b", "a"]
  end

  test "returns an empty list when nothing matches", ctx do
    assert DOM.get_elements_by_tag_name(ctx.document, "missing") == []
  end

  test "scopes the search to an element's descendants, excluding itself", ctx do
    matches = DOM.get_elements_by_tag_name(ctx.b, "a")

    assert Enum.map(matches, & &1.id) == [ctx.a2.id]
    assert DOM.get_elements_by_tag_name(ctx.b, "b") == []
  end
end
