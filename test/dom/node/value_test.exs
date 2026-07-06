defmodule DOM.Node.ValueTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  test "returns text data and nil for nodes without a value" do
    document = DOM.new()
    element = DOM.create_element(document, "element")
    text = DOM.create_text_node(document, "text")
    comment = DOM.create_comment(document, "comment")

    assert Node.value(text) == "text"
    assert Node.value(comment) == "comment"
    refute Node.value(element)
    refute Node.value(document)
  end
end
