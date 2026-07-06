defmodule DOM.Node.RemoveChildTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  test "removes a child and returns it, clearing its parent" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")
    Node.append_child(parent, first)
    Node.append_child(parent, second)

    assert Node.remove_child(parent, first) == first
    assert Node.child_nodes(parent) == [second]
    refute Node.parent_node(first)
  end

  test "keeps the removed node's own subtree intact" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    child = DOM.create_element(document, "child")
    grandchild = DOM.create_element(document, "grandchild")
    Node.append_child(parent, child)
    Node.append_child(child, grandchild)

    Node.remove_child(parent, child)

    assert Node.child_nodes(child) == [grandchild]
    assert Node.parent_node(grandchild) == child
  end

  test "raises NotFoundError when the node is not a child of the parent" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    stranger = DOM.create_element(document, "stranger")

    assert_raise DOM.NotFoundError, fn ->
      Node.remove_child(parent, stranger)
    end

    assert Node.child_nodes(parent) == []
  end
end
