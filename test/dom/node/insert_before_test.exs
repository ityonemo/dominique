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

  test "inserts a fragment's children before the reference child and empties it" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    reference = DOM.create_element(document, "reference")
    fragment = DOM.create_document_fragment(document)
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")
    Node.append_child(parent, reference)
    Node.append_child(fragment, first)
    Node.append_child(fragment, second)

    Node.insert_before(parent, fragment, reference)

    assert Node.child_nodes(parent) == [first, second, reference]
    assert Node.child_nodes(fragment) == []
    assert Node.parent_node(first) == parent
    assert Node.parent_node(second) == parent
  end

  test "adopts a child from another document before the reference child" do
    alias DOM.Node.Element

    source = DOM.new()
    destination = DOM.new()
    parent = DOM.create_element(destination, "parent")
    reference = DOM.create_element(destination, "reference")
    child = DOM.create_element(source, "child")
    Node.append_child(parent, reference)

    inserted = Node.insert_before(parent, child, reference)

    assert inserted.server == destination.server

    assert parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1) == [
             "child",
             "reference"
           ]

    assert Node.parent_node(inserted) == parent
  end
end
