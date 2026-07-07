defmodule DOM.Node.ReplaceChildTest do
  use ExUnit.Case, async: true

  alias DOM.Element
  alias DOM.Node

  test "replaces the old child in place and returns the old child" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    first = DOM.create_element(document, "first")
    old = DOM.create_element(document, "old")
    last = DOM.create_element(document, "last")
    new = DOM.create_element(document, "new")
    Node.append_child(parent, first)
    Node.append_child(parent, old)
    Node.append_child(parent, last)

    assert Node.replace_child(parent, new, old) == old

    assert parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1) == [
             "first",
             "new",
             "last"
           ]

    assert Node.parent_node(new) == parent
    refute Node.parent_node(old)
  end

  test "raises NotFoundError when the old child is not a child of the parent" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    new = DOM.create_element(document, "new")
    stranger = DOM.create_element(document, "stranger")

    assert_raise DOM.NotFoundError, fn ->
      Node.replace_child(parent, new, stranger)
    end

    assert Node.child_nodes(parent) == []
    refute Node.parent_node(new)
  end

  test "replaces the document element with another element" do
    document = DOM.new()
    old_root = DOM.create_element(document, "old-root")
    new_root = DOM.create_element(document, "new-root")
    Node.append_child(document, old_root)

    assert Node.replace_child(document, new_root, old_root) == old_root
    assert document |> Node.child_nodes() |> Enum.map(&Element.local_name/1) == ["new-root"]
  end

  test "replacing a child with itself leaves the tree unchanged" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")
    Node.append_child(parent, first)
    Node.append_child(parent, second)

    assert Node.replace_child(parent, first, first) == first
    assert Node.child_nodes(parent) == [first, second]
    assert Node.parent_node(first) == parent
  end

  test "replaces a child with a document fragment's children" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    old = DOM.create_element(document, "old")
    fragment = DOM.create_document_fragment(document)
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")
    Node.append_child(parent, old)
    Node.append_child(fragment, first)
    Node.append_child(fragment, second)

    Node.replace_child(parent, fragment, old)

    assert parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1) == ["first", "second"]
    assert Node.child_nodes(fragment) == []
    refute Node.parent_node(old)
  end
end
