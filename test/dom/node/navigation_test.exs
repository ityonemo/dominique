defmodule DOM.Node.NavigationTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  setup do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    first = DOM.create_element(document, "first")
    middle = DOM.create_element(document, "middle")
    last = DOM.create_element(document, "last")
    Node.append_child(parent, first)
    Node.append_child(parent, middle)
    Node.append_child(parent, last)

    %{document: document, parent: parent, first: first, middle: middle, last: last}
  end

  test "first_child and last_child return the boundary children", ctx do
    assert Node.first_child(ctx.parent) == ctx.first
    assert Node.last_child(ctx.parent) == ctx.last
  end

  test "first_child and last_child are nil for a childless node", ctx do
    assert Node.first_child(ctx.first) == nil
    assert Node.last_child(ctx.first) == nil
  end

  test "next_sibling walks forward and stops at the end", ctx do
    assert Node.next_sibling(ctx.first) == ctx.middle
    assert Node.next_sibling(ctx.middle) == ctx.last
    assert Node.next_sibling(ctx.last) == nil
  end

  test "previous_sibling walks backward and stops at the start", ctx do
    assert Node.previous_sibling(ctx.last) == ctx.middle
    assert Node.previous_sibling(ctx.middle) == ctx.first
    assert Node.previous_sibling(ctx.first) == nil
  end

  test "a node without a parent has no siblings", ctx do
    orphan = DOM.create_element(ctx.document, "orphan")

    assert Node.next_sibling(orphan) == nil
    assert Node.previous_sibling(orphan) == nil
  end
end
