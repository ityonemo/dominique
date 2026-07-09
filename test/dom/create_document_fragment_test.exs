defmodule DOM.CreateDocumentFragmentTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  test "creates a unique detached node owned by the document server" do
    document = DOM.new()
    first = DOM.create_document_fragment(document)
    second = DOM.create_document_fragment(document)

    assert first.server == document.server
    assert second.server == document.server
    refute first.node_id == second.node_id
    refute Node.parent_node(first)
    assert Node.child_nodes(first) == []
  end

  test "rejects creation from a non-document node" do
    document = DOM.new()
    element = DOM.create_element(document, "element")

    assert_raise DOM.HierarchyRequestError, fn ->
      DOM.create_document_fragment(element)
    end
  end
end
