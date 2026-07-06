defmodule DOM.Node.ParentNodeTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  test "returns nil for a detached node and its parent after insertion" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    child = DOM.create_element(document, "child")

    refute Node.parent_node(child)

    Node.append_child(parent, child)

    assert Node.parent_node(child) == parent
  end
end
