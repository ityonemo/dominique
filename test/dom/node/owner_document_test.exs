defmodule DOM.Node.OwnerDocumentTest do
  use ExUnit.Case, async: true

  alias DOM.Node
  alias DOM.Node.Document

  test "a node's owner document is the document that created it" do
    document = DOM.new()
    element = DOM.create_element(document, "element")

    assert %Document{} = owner = Node.owner_document(element)
    assert owner.server == document.server
    assert owner.id == document.id
  end

  test "the owner document is stable across node types" do
    document = DOM.new()
    text = DOM.create_text_node(document, "text")
    comment = DOM.create_comment(document, "comment")
    fragment = DOM.create_document_fragment(document)

    assert Node.owner_document(text).id == document.id
    assert Node.owner_document(comment).id == document.id
    assert Node.owner_document(fragment).id == document.id
  end

  test "the document itself has no owner document" do
    document = DOM.new()

    assert Node.owner_document(document) == nil
  end
end
