defmodule DOM.Node.AppendChildTest do
  use ExUnit.Case, async: true

  alias DOM.Node
  alias DOM.Node.Comment
  alias DOM.Node.Document
  alias DOM.Node.DocumentType
  alias DOM.Node.Element
  alias DOM.Node.Text

  test "returns the child and updates both sides of the relationship" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    child = DOM.create_element(document, "child")

    assert Node.append_child(parent, child) == child
    assert Node.child_nodes(parent) == [child]
    assert Node.parent_node(child) == parent
  end

  test "moving a child removes every stale relationship" do
    document = DOM.new()
    old_parent = DOM.create_element(document, "old-parent")
    new_parent = DOM.create_element(document, "new-parent")
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")

    Node.append_child(old_parent, first)
    Node.append_child(old_parent, second)
    Node.append_child(new_parent, first)

    assert Node.child_nodes(old_parent) == [second]
    assert Node.child_nodes(new_parent) == [first]
    assert Node.parent_node(first) == new_parent
  end

  test "a rejected mutation leaves every relationship unchanged" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    child = DOM.create_element(document, "child")
    Node.append_child(parent, child)

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(child, parent)
    end

    assert Node.child_nodes(parent) == [child]
    assert Node.child_nodes(child) == []
    refute Node.parent_node(parent)
    assert Node.parent_node(child) == parent
  end

  test "a leaf node cannot acquire children" do
    document = DOM.new()
    text = DOM.create_text_node(document, "text")
    child = DOM.create_element(document, "child")

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(text, child)
    end

    assert Node.child_nodes(text) == []
    refute Node.parent_node(child)
    assert Node.value(text) == "text"
  end

  test "a document rejects a text child without changing either node" do
    document = DOM.new()
    text = DOM.create_text_node(document, "text")

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(document, text)
    end

    assert Node.child_nodes(document) == []
    refute Node.parent_node(text)
    assert Node.value(text) == "text"
  end

  test "a comment leaf cannot acquire children" do
    document = DOM.new()
    comment = DOM.create_comment(document, "comment")
    child = DOM.create_element(document, "child")

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(comment, child)
    end

    assert Node.child_nodes(comment) == []
    refute Node.parent_node(child)
    assert Node.value(comment) == "comment"
  end

  test "a document type leaf cannot acquire children" do
    document = DOM.new()
    document_type = DOM.create_document_type(document, "html", "", "")
    child = DOM.create_element(document, "child")

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(document_type, child)
    end

    assert Node.child_nodes(document_type) == []
    refute Node.parent_node(child)
  end

  test "type-invalid insertions reject without consulting document state" do
    document = %Document{server: self(), id: make_ref()}
    element = %Element{server: self(), id: make_ref()}
    text = %Text{server: self(), id: make_ref()}
    comment = %Comment{server: self(), id: make_ref()}
    document_type = %DocumentType{server: self(), id: make_ref()}

    assert_raise DOM.HierarchyRequestError, fn -> Node.append_child(text, element) end
    assert_raise DOM.HierarchyRequestError, fn -> Node.append_child(comment, element) end
    assert_raise DOM.HierarchyRequestError, fn -> Node.append_child(element, document) end
    assert_raise DOM.HierarchyRequestError, fn -> Node.append_child(element, document_type) end
    assert_raise DOM.HierarchyRequestError, fn -> Node.append_child(document, document) end
    assert_raise DOM.HierarchyRequestError, fn -> Node.append_child(document, text) end
  end

  test "a document rejects a second document type without changing either node" do
    document = DOM.new()
    first = DOM.create_document_type(document, "first", "", "")
    second = DOM.create_document_type(document, "second", "", "")
    Node.append_child(document, first)

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(document, second)
    end

    assert Node.child_nodes(document) == [first]
    refute Node.parent_node(second)
  end

  test "a document rejects a document type after its element" do
    document = DOM.new()
    element = DOM.create_element(document, "element")
    document_type = DOM.create_document_type(document, "html", "", "")
    Node.append_child(document, element)

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(document, document_type)
    end

    assert Node.child_nodes(document) == [element]
    refute Node.parent_node(document_type)
  end

  test "transfers a subtree and returns its destination-owned handle" do
    source = DOM.new()
    destination = DOM.new()
    parent = DOM.create_element(destination, "parent")
    child = DOM.create_element(source, "child")
    grandchild = DOM.create_element(source, "grandchild")
    Node.append_child(child, grandchild)

    transferred_child = Node.append_child(parent, child)
    [transferred_grandchild] = Node.child_nodes(transferred_child)

    assert transferred_child.server == destination.server
    assert transferred_child.id == child.id
    assert transferred_grandchild.server == destination.server
    assert Node.child_nodes(parent) == [transferred_child]
    assert Node.parent_node(transferred_child) == parent
    assert Node.parent_node(transferred_grandchild) == transferred_child
  end

  test "inserts a document fragment's children and empties the fragment" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    fragment = DOM.create_document_fragment(document)
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")
    Node.append_child(fragment, first)
    Node.append_child(fragment, second)

    assert Node.append_child(parent, fragment) == fragment
    assert Node.child_nodes(parent) == [first, second]
    assert Node.child_nodes(fragment) == []
    assert Node.parent_node(first) == parent
    assert Node.parent_node(second) == parent
    refute Node.parent_node(fragment)
  end

  test "a document rejects fragment contents that cannot be its children" do
    document = DOM.new()
    text_fragment = DOM.create_document_fragment(document)
    text = DOM.create_text_node(document, "text")
    Node.append_child(text_fragment, text)

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(document, text_fragment)
    end

    assert Node.child_nodes(document) == []
    assert Node.child_nodes(text_fragment) == [text]
    assert Node.parent_node(text) == text_fragment

    element_fragment = DOM.create_document_fragment(document)
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")
    Node.append_child(element_fragment, first)
    Node.append_child(element_fragment, second)

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(document, element_fragment)
    end

    assert Node.child_nodes(document) == []
    assert Node.child_nodes(element_fragment) == [first, second]
    assert Node.parent_node(first) == element_fragment
    assert Node.parent_node(second) == element_fragment
  end

  test "transfers and splices a document fragment across DOM servers" do
    source = DOM.new()
    destination = DOM.new()
    parent = DOM.create_element(destination, "parent")
    fragment = DOM.create_document_fragment(source)
    first = DOM.create_element(source, "first")
    second = DOM.create_element(source, "second")
    Node.append_child(fragment, first)
    Node.append_child(fragment, second)

    transferred_fragment = Node.append_child(parent, fragment)
    [transferred_first, transferred_second] = Node.child_nodes(parent)

    assert transferred_fragment.server == destination.server
    assert transferred_fragment.id == fragment.id
    assert Node.child_nodes(transferred_fragment) == []
    assert Enum.map([transferred_first, transferred_second], & &1.id) == [first.id, second.id]
    assert transferred_first.server == destination.server
    assert transferred_second.server == destination.server
    assert Node.parent_node(transferred_first) == parent
    assert Node.parent_node(transferred_second) == parent
    refute Node.parent_node(transferred_fragment)
  end

  test "validates an exported fragment before transferring it to a document" do
    source = DOM.new()
    destination = DOM.new()
    fragment = DOM.create_document_fragment(source)
    element = DOM.create_element(source, "element")
    Node.append_child(fragment, element)

    transferred_fragment = Node.append_child(destination, fragment)
    [transferred_element] = Node.child_nodes(destination)

    assert transferred_element.id == element.id
    assert transferred_element.server == destination.server
    assert Node.child_nodes(transferred_fragment) == []

    rejected_fragment = DOM.create_document_fragment(source)
    text = DOM.create_text_node(source, "text")
    Node.append_child(rejected_fragment, text)

    assert_raise DOM.HierarchyRequestError, fn ->
      Node.append_child(destination, rejected_fragment)
    end

    assert Node.child_nodes(rejected_fragment) == [text]
    assert Node.parent_node(text) == rejected_fragment
  end
end
