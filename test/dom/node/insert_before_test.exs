defmodule DOM.Node.InsertBeforeTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  test "inserts a child immediately before the reference child" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")
    Node.append_child(parent, second)

    assert Node.insert_before(parent, first, second) == first
    assert Node.child_nodes(parent) == [first, second]
    assert Node.parent_node(first) == parent
  end

  test "appends the child when the reference child is nil" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")
    Node.append_child(parent, first)

    assert Node.insert_before(parent, second, nil) == second
    assert Node.child_nodes(parent) == [first, second]
    assert Node.parent_node(second) == parent
  end

  test "raises NotFoundError when the reference child is not a child of the parent" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    child = DOM.create_element(document, "child")
    stranger = DOM.create_element(document, "stranger")

    assert_raise DOM.NotFoundError, fn ->
      Node.insert_before(parent, child, stranger)
    end

    refute Node.parent_node(child)
    assert Node.child_nodes(parent) == []
  end
end
