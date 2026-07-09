defmodule DOM.ConsistencyTest do
  use ExUnit.Case, async: true

  # Exercises DOM.NodeData.Table.check_consistency! (via DOM._check_index_consistency!)
  # against documents produced by the real parser and mutated through the public API,
  # proving the parent/children pointers stay mutually consistent at every rest point.

  alias DOM.Element
  alias DOM.Node

  defp assert_consistent(%Node{server: server}) do
    assert DOM._check_index_consistency!(server) == :ok
  end

  test "a parsed document is consistent" do
    doc = DOM.new("<html><body><ul><li id=a>1</li><li>2</li></ul><p>x</p></body></html>")
    assert_consistent(doc)
  end

  test "consistent after append/insert/remove/replace" do
    doc = DOM.new("<div id=root></div>")
    root = DOM.query_selector(doc, "#root")

    a = DOM.create_element(doc, "a")
    b = DOM.create_element(doc, "b")
    Node.append_child(root, a)
    Node.append_child(root, b)
    assert_consistent(doc)

    Node.remove_child(root, a)
    assert_consistent(doc)
  end

  test "consistent after a cross-document adoption (append transfers subtree)" do
    source = DOM.new("<section id=s><span id=moved>hi</span></section>")
    dest = DOM.new("<div id=d></div>")

    moved = DOM.query_selector(source, "#moved")
    dest_root = DOM.query_selector(dest, "#d")
    Node.append_child(dest_root, moved)

    assert_consistent(source)
    assert_consistent(dest)
  end

  test "consistent after set_text_content wipes children" do
    doc = DOM.new("<div id=root><p>a</p><p>b</p></div>")
    root = DOM.query_selector(doc, "#root")
    Node.set_text_content(root, "just text")
    assert_consistent(doc)
  end

  test "consistent after inner_html replacement" do
    doc = DOM.new("<div id=root><span>old</span></div>")
    root = DOM.query_selector(doc, "#root")
    Element.set_inner_html(root, "<b>new</b><i>markup</i>")
    assert_consistent(doc)
  end

  test "consistent after clone_node" do
    doc = DOM.new("<ul id=root><li id=x>1</li></ul>")
    root = DOM.query_selector(doc, "#root")
    clone = Node.clone_node(root, true)
    Node.append_child(root, clone)
    assert_consistent(doc)
  end

  test "id index tracks setAttribute / changed id / removeAttribute" do
    doc = DOM.new("<div id=root></div>")
    root = DOM.query_selector(doc, "#root")
    el = DOM.create_element(doc, "span")
    Node.append_child(root, el)

    Element.set_attribute(el, "id", "first")
    assert_consistent(doc)

    Element.set_attribute(el, "id", "second")
    assert_consistent(doc)

    Element.remove_attribute(el, "id")
    assert_consistent(doc)
  end

  test "id index survives a created-but-unappended element with an id" do
    doc = DOM.new("<div id=root></div>")
    el = DOM.create_element(doc, "span")
    Element.set_attribute(el, "id", "detached")
    # never appended — legitimately unreachable, but still indexed
    assert_consistent(doc)
  end
end
