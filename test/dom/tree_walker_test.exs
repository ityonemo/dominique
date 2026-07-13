defmodule DOM.TreeWalkerTest do
  use DOM.Case, async: true

  # TreeWalker: depth-first document-order traversal with a whatToShow node-type filter
  # and an optional accept/skip/reject callback. Stateful (server-side); nextNode
  # excludes the root. Browser-verified in treewalker-nodeiterator-semantics memory.

  alias DOM.TreeWalker

  defp id(nil), do: nil
  defp id(node), do: DOM.Element.get_attribute(node, "id")

  # tree: root > (a > (b, c)), d, then text nodes inside
  defp tree do
    doc =
      new_document(
        "<body><div id='root'><div id='a'><span id='b'>t1</span><span id='c'>t2</span></div>" <>
          "<p id='d'>t3</p></div></body>"
      )

    {doc, DOM.query_selector(doc, "#root")}
  end

  defp drain(walker) do
    case TreeWalker.next_node(walker) do
      nil -> []
      node -> [id(node) || DOM.Node.node_name(node) | drain(walker)]
    end
  end

  test "nextNode walks elements in document order, excluding the root" do
    {_doc, root} = tree()
    w = DOM.create_tree_walker(root, :element)
    assert drain(w) == ["a", "b", "c", "d"]
  end

  test "whatToShow :text yields only text nodes" do
    {_doc, root} = tree()
    w = DOM.create_tree_walker(root, :text)

    texts =
      Stream.repeatedly(fn -> TreeWalker.next_node(w) end)
      |> Enum.take_while(& &1)
      |> Enum.map(&DOM.Node.value/1)

    assert texts == ["t1", "t2", "t3"]
  end

  test "navigation methods move currentNode" do
    {doc, root} = tree()
    w = DOM.create_tree_walker(root, :element)

    assert id(TreeWalker.first_child(w)) == "a"
    assert id(TreeWalker.first_child(w)) == "b"
    assert id(TreeWalker.next_sibling(w)) == "c"
    assert id(TreeWalker.parent_node(w)) == "a"
    assert id(TreeWalker.last_child(w)) == "c"

    _ = doc
  end

  test "current_node is settable and readable" do
    {doc, root} = tree()
    c = DOM.query_selector(doc, "#c")
    w = DOM.create_tree_walker(root, :element)

    TreeWalker.set_current_node(w, c)
    assert id(TreeWalker.current_node(w)) == "c"
    assert id(TreeWalker.parent_node(w)) == "a"
  end

  test "a filter returning :reject skips the node AND its subtree" do
    {_doc, root} = tree()
    reject_a = fn node -> if id(node) == "a", do: :reject, else: :accept end
    w = DOM.create_tree_walker(root, :element, reject_a)
    assert drain(w) == ["d"]
  end

  test "a filter returning :skip skips the node but keeps its descendants" do
    {_doc, root} = tree()
    skip_a = fn node -> if id(node) == "a", do: :skip, else: :accept end
    w = DOM.create_tree_walker(root, :element, skip_a)
    assert drain(w) == ["b", "c", "d"]
  end

  test "previousNode walks back up" do
    {doc, root} = tree()
    c = DOM.query_selector(doc, "#c")
    w = DOM.create_tree_walker(root, :element)
    TreeWalker.set_current_node(w, c)

    assert id(TreeWalker.previous_node(w)) == "b"
    assert id(TreeWalker.previous_node(w)) == "a"
    # previousNode does not go above the root
    assert TreeWalker.previous_node(w) == nil
  end
end
