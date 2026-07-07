defmodule DOM.GetElementByIdTest do
  use ExUnit.Case, async: true

  alias DOM.Element
  alias DOM.Node

  setup do
    document = DOM.new()
    root = DOM.create_element(document, "root")
    Node.append_child(document, root)
    %{document: document, root: root}
  end

  test "returns the descendant element with the matching id", ctx do
    target = DOM.create_element(ctx.document, "target")
    Element.set_attribute(target, "id", "wanted")
    Node.append_child(ctx.root, target)

    assert DOM.get_element_by_id(ctx.document, "wanted").id == target.id
  end

  test "returns nil when no element has the id", ctx do
    plain = DOM.create_element(ctx.document, "plain")
    Node.append_child(ctx.root, plain)

    assert DOM.get_element_by_id(ctx.document, "missing") == nil
  end

  test "returns the first match in tree order", ctx do
    first = DOM.create_element(ctx.document, "first")
    second = DOM.create_element(ctx.document, "second")
    Element.set_attribute(first, "id", "dup")
    Element.set_attribute(second, "id", "dup")
    Node.append_child(ctx.root, first)
    Node.append_child(ctx.root, second)

    assert DOM.get_element_by_id(ctx.document, "dup").id == first.id
  end
end
