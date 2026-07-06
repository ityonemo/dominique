defmodule DOM.CreateElementTest do
  use ExUnit.Case, async: true

  alias DOM.Node
  alias DOM.Node.Element

  test "creates a unique detached node owned by the document server" do
    document = DOM.new()
    first = DOM.create_element(document, "element")
    second = DOM.create_element(document, "element")

    assert first.server == document.server
    assert second.server == document.server
    refute first.id == document.id
    refute first.id == second.id
    refute Node.parent_node(first)
    assert Node.child_nodes(first) == []
  end

  test "rejects creation from a non-document node" do
    element = %Element{server: self(), id: make_ref()}

    assert_raise DOM.HierarchyRequestError, fn ->
      DOM.create_element(element, "child")
    end
  end
end
