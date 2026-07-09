defmodule DOM.Node.CloneNodeTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node

  test "clones an element as a fresh detached handle preserving its name" do
    document = new_document()
    original = DOM.create_element(document, "widget")

    clone = Node.clone_node(original)

    refute clone.id == original.id
    assert clone.server == original.server
    assert Element.local_name(clone) == "widget"
    refute Node.parent_node(clone)
  end

  test "clones character-data value" do
    document = new_document()
    text = DOM.create_text_node(document, "hello")
    comment = DOM.create_comment(document, "note")

    assert Node.value(Node.clone_node(text)) == "hello"
    assert Node.value(Node.clone_node(comment)) == "note"
  end

  test "a shallow clone omits children" do
    document = new_document()
    parent = DOM.create_element(document, "parent")
    Node.append_child(parent, DOM.create_element(document, "child"))

    clone = Node.clone_node(parent)

    assert Node.child_nodes(clone) == []
  end

  test "a deep clone copies the whole subtree independently" do
    document = new_document()
    parent = DOM.create_element(document, "parent")
    child = DOM.create_element(document, "child")
    Node.append_child(parent, child)
    Node.append_child(child, DOM.create_text_node(document, "leaf"))

    clone = Node.clone_node(parent, true)

    [cloned_child] = Node.child_nodes(clone)
    assert Element.local_name(cloned_child) == "child"
    refute cloned_child.id == child.id
    assert Node.text_content(clone) == "leaf"

    # mutating the clone does not touch the original
    Node.append_child(clone, DOM.create_element(document, "extra"))
    assert parent |> Node.child_nodes() |> length() == 1
  end

  test "clones a document type's identity" do
    document = new_document()
    doctype = DOM.create_document_type(document, "html", "pub", "sys")

    clone = Node.clone_node(doctype)

    assert Node.node_name(clone) == "html"
    refute clone.id == doctype.id
  end
end
