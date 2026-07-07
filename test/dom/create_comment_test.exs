defmodule DOM.CreateCommentTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  test "creates a unique detached node owned by the document server" do
    document = DOM.new()
    first = DOM.create_comment(document, "first")
    second = DOM.create_comment(document, "second")

    assert first.server == document.server
    assert second.server == document.server
    refute first.id == second.id
    refute Node.parent_node(first)
    assert Node.child_nodes(first) == []
  end

  test "rejects creation from a non-document node" do
    element = %DOM.Node{type: :element, server: self(), id: make_ref()}

    assert_raise DOM.HierarchyRequestError, fn ->
      DOM.create_comment(element, "comment")
    end
  end
end
