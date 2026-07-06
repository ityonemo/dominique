defmodule DOM.Node.ChildNodesTest do
  use ExUnit.Case, async: true

  alias DOM.Node
  alias DOM.Node.Comment
  alias DOM.Node.Text

  test "returns direct children in tree order" do
    document = DOM.new()
    parent = DOM.create_element(document, "parent")
    first = DOM.create_element(document, "first")
    second = DOM.create_element(document, "second")

    assert Node.child_nodes(parent) == []

    assert parent
           |> tap(&Node.append_child(&1, first))
           |> tap(&Node.append_child(&1, second))
           |> Node.child_nodes() == [first, second]
  end

  test "leaf nodes return no children without consulting their server" do
    text = %Text{server: self(), id: make_ref()}
    comment = %Comment{server: self(), id: make_ref()}

    assert Node.child_nodes(text) == []
    assert Node.child_nodes(comment) == []
  end
end
