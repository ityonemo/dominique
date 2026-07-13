defmodule DOM.NodeIteratorTest do
  use DOM.Case, async: true

  # NodeIterator: document-order traversal INCLUDING the root; nextNode/previousNode;
  # and the live reference-node adjustment on removal (iteration survives removing the
  # reference node). Browser-verified.

  alias DOM.Node
  alias DOM.NodeIterator

  defp id(nil), do: nil
  defp id(node), do: DOM.Element.get_attribute(node, "id")

  defp tree do
    doc =
      new_document(
        "<body><div id='root'><span id='a'></span><span id='b'></span><span id='c'></span></div></body>"
      )

    {doc, DOM.query_selector(doc, "#root")}
  end

  defp drain(it) do
    case NodeIterator.next_node(it) do
      nil -> []
      node -> [id(node) || "root" | drain(it)]
    end
  end

  test "nextNode walks elements in document order INCLUDING the root" do
    {_doc, root} = tree()
    it = DOM.create_node_iterator(root, :element)
    assert drain(it) == ["root", "a", "b", "c"]
  end

  test "previousNode walks back through the visited set" do
    {_doc, root} = tree()
    it = DOM.create_node_iterator(root, :element)
    NodeIterator.next_node(it)
    NodeIterator.next_node(it)
    NodeIterator.next_node(it)
    # referenceNode is now b (root, a, b)

    assert id(NodeIterator.previous_node(it)) == "b"
    assert id(NodeIterator.previous_node(it)) == "a"
    assert id(NodeIterator.previous_node(it)) == "root"
    assert NodeIterator.previous_node(it) == nil
  end

  test "removing the reference node adjusts the iterator so nextNode continues" do
    {doc, root} = tree()
    it = DOM.create_node_iterator(root, :element)
    NodeIterator.next_node(it)
    NodeIterator.next_node(it)
    NodeIterator.next_node(it)
    # referenceNode is now b; remove it
    Node.remove_child(root, DOM.query_selector(doc, "#b"))

    # iteration survives: next is c
    assert id(NodeIterator.next_node(it)) == "c"
  end

  test ":all yields every node type in document order" do
    doc = new_document("<body><div id='r'>txt<span id='s'>y</span><!--c--></div></body>")
    r = DOM.query_selector(doc, "#r")
    it = DOM.create_node_iterator(r, :all)

    kinds =
      Stream.repeatedly(fn -> NodeIterator.next_node(it) end)
      |> Enum.take_while(& &1)
      |> Enum.map(&DOM.Node.node_type/1)

    # r(element), txt(text 3), s(element 1), y(text 3), comment(8)
    assert kinds == [1, 3, 1, 3, 8]
  end
end
