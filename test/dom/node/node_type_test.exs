defmodule DOM.Node.NodeTypeTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  setup do
    %{document: DOM.new()}
  end

  test "node_type returns the spec constant for each node type", %{document: document} do
    assert Node.node_type(document) == 9
    assert Node.node_type(DOM.create_element(document, "el")) == 1
    assert Node.node_type(DOM.create_text_node(document, "t")) == 3
    assert Node.node_type(DOM.create_comment(document, "c")) == 8
    assert Node.node_type(DOM.create_document_type(document, "html", "", "")) == 10
    assert Node.node_type(DOM.create_document_fragment(document)) == 11
  end

  test "node_name reflects the type or name for each node type", %{document: document} do
    assert Node.node_name(document) == "#document"
    assert Node.node_name(DOM.create_element(document, "div")) == "div"
    assert Node.node_name(DOM.create_text_node(document, "t")) == "#text"
    assert Node.node_name(DOM.create_comment(document, "c")) == "#comment"
    assert Node.node_name(DOM.create_document_type(document, "html", "", "")) == "html"
    assert Node.node_name(DOM.create_document_fragment(document)) == "#document-fragment"
  end
end
