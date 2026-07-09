defmodule DOM.GetElementByIdTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node

  setup do
    document = new_document()
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

  test "scopes the search to the given root's descendants", ctx do
    branch = DOM.create_element(ctx.document, "branch")
    inside = DOM.create_element(ctx.document, "inside")
    Element.set_attribute(inside, "id", "scoped")
    Node.append_child(branch, inside)
    Node.append_child(ctx.root, branch)

    outside = DOM.create_element(ctx.document, "outside")
    Element.set_attribute(outside, "id", "elsewhere")
    Node.append_child(ctx.root, outside)

    # get_element_by_id on `branch` sees only its subtree.
    assert DOM.get_element_by_id(branch, "scoped").id == inside.id
    assert DOM.get_element_by_id(branch, "elsewhere") == nil
  end

  test "finds an id set after the element was appended", ctx do
    el = DOM.create_element(ctx.document, "late")
    Node.append_child(ctx.root, el)
    assert DOM.get_element_by_id(ctx.document, "late-id") == nil

    Element.set_attribute(el, "id", "late-id")
    assert DOM.get_element_by_id(ctx.document, "late-id").id == el.id
  end

  test "stops finding an id after it is removed", ctx do
    el = DOM.create_element(ctx.document, "gone")
    Element.set_attribute(el, "id", "temp")
    Node.append_child(ctx.root, el)
    assert DOM.get_element_by_id(ctx.document, "temp").id == el.id

    Element.remove_attribute(el, "id")
    assert DOM.get_element_by_id(ctx.document, "temp") == nil
  end
end
