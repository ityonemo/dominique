defmodule DOM.Node.NormalizeTest do
  use DOM.Case, async: true

  # T3: Node.normalize — merge adjacent Text siblings into one, drop empty Text
  # nodes, recursively over the subtree.

  alias DOM.Node

  defp kinds_and_values(node) do
    node |> Node.child_nodes() |> Enum.map(&{&1.type, Node.value(&1)})
  end

  test "merges adjacent text nodes into one" do
    doc = new_document("<div id='p'></div>")
    p = DOM.query_selector(doc, "#p")
    Node.append(p, ["a", "b", "c"])
    assert length(Node.child_nodes(p)) == 3

    Node.normalize(p)
    assert kinds_and_values(p) == [{:text, "abc"}]
  end

  test "drops empty text nodes" do
    doc = new_document("<div id='p'></div>")
    p = DOM.query_selector(doc, "#p")
    Node.append(p, ["x", "", "y"])

    Node.normalize(p)
    assert kinds_and_values(p) == [{:text, "xy"}]
  end

  test "does not merge text separated by an element" do
    doc = new_document("<div id='p'></div>")
    p = DOM.query_selector(doc, "#p")
    a = DOM.create_element(doc, "b")
    Node.append(p, ["one", a, "two"])

    Node.normalize(p)

    assert [{:text, "one"}, {:element, nil}, {:text, "two"}] = kinds_and_values(p)
  end

  test "normalizes recursively into descendants" do
    doc = new_document("<div id='p'><span id='s'></span></div>")
    p = DOM.query_selector(doc, "#p")
    s = DOM.query_selector(doc, "#s")
    Node.append(s, ["deep", "ly"])

    Node.normalize(p)
    assert kinds_and_values(s) == [{:text, "deeply"}]
  end

  test "an all-empty run leaves no text children" do
    doc = new_document("<div id='p'></div>")
    p = DOM.query_selector(doc, "#p")
    Node.append(p, ["", ""])

    Node.normalize(p)
    assert Node.child_nodes(p) == []
  end
end
