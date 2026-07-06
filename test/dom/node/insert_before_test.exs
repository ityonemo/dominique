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
end
