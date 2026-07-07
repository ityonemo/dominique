defmodule DOM.GetElementsByClassNameTest do
  use ExUnit.Case, async: true

  alias DOM.Element
  alias DOM.Node

  setup do
    document = DOM.new()
    root = DOM.create_element(document, "root")
    Node.append_child(document, root)
    %{document: document, root: root}
  end

  test "returns descendants carrying the class in tree order", ctx do
    a = element(ctx, "a", "box")
    _plain = element(ctx, "plain", nil)
    b = element(ctx, "b", "box highlight")

    matches = DOM.get_elements_by_class_name(ctx.document, "box")

    assert Enum.map(matches, & &1.id) == [a.id, b.id]
  end

  test "requires every requested class token to be present", ctx do
    _only_box = element(ctx, "a", "box")
    both = element(ctx, "b", "highlight box")

    matches = DOM.get_elements_by_class_name(ctx.document, "box highlight")

    assert Enum.map(matches, & &1.id) == [both.id]
  end

  test "returns an empty list for an empty query", ctx do
    element(ctx, "a", "box")

    assert DOM.get_elements_by_class_name(ctx.document, "") == []
    assert DOM.get_elements_by_class_name(ctx.document, "   ") == []
  end

  test "scopes to an element's descendants", ctx do
    outer = element(ctx, "outer", "box")
    inner = DOM.create_element(ctx.document, "inner")
    Element.set_attribute(inner, "class", "box")
    Node.append_child(outer, inner)

    matches = DOM.get_elements_by_class_name(outer, "box")

    assert Enum.map(matches, & &1.id) == [inner.id]
  end

  defp element(ctx, name, class) do
    node = DOM.create_element(ctx.document, name)
    if class, do: Element.set_attribute(node, "class", class)
    Node.append_child(ctx.root, node)
    node
  end
end
