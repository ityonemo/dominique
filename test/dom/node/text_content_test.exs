defmodule DOM.Node.TextContentTest do
  use ExUnit.Case, async: true

  alias DOM.Node

  test "returns a character-data node's own value" do
    document = DOM.new()
    text = DOM.create_text_node(document, "hello")
    comment = DOM.create_comment(document, "note")

    assert Node.text_content(text) == "hello"
    assert Node.text_content(comment) == "note"
  end

  test "concatenates descendant text of an element in tree order" do
    document = DOM.new()
    root = DOM.create_element(document, "root")
    child = DOM.create_element(document, "child")
    Node.append_child(root, DOM.create_text_node(document, "a"))
    Node.append_child(root, child)
    Node.append_child(child, DOM.create_text_node(document, "b"))
    Node.append_child(root, DOM.create_text_node(document, "c"))

    assert Node.text_content(root) == "abc"
  end

  test "ignores comment descendants" do
    document = DOM.new()
    root = DOM.create_element(document, "root")
    Node.append_child(root, DOM.create_text_node(document, "x"))
    Node.append_child(root, DOM.create_comment(document, "hidden"))
    Node.append_child(root, DOM.create_text_node(document, "y"))

    assert Node.text_content(root) == "xy"
  end

  test "an element with no text descendants yields an empty string" do
    document = DOM.new()
    root = DOM.create_element(document, "root")

    assert Node.text_content(root) == ""
  end

  test "concatenates a document fragment's descendant text" do
    document = DOM.new()
    fragment = DOM.create_document_fragment(document)
    Node.append_child(fragment, DOM.create_text_node(document, "frag"))

    assert Node.text_content(fragment) == "frag"
  end

  test "a document has no text content" do
    document = DOM.new()

    assert Node.text_content(document) == nil
  end

  test "a document type has no text content" do
    document = DOM.new()
    doctype = DOM.create_document_type(document, "html", "", "")

    assert Node.text_content(doctype) == nil
  end

  describe "set_text_content/2" do
    test "replaces an element's children with a single text node" do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      Node.append_child(root, DOM.create_element(document, "old"))
      Node.append_child(root, DOM.create_text_node(document, "gone"))

      Node.set_text_content(root, "fresh")

      assert Node.text_content(root) == "fresh"
      assert [text] = Node.child_nodes(root)
      assert Node.value(text) == "fresh"
      assert Node.parent_node(text) == root
    end

    test "an empty value removes all children and inserts nothing" do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      Node.append_child(root, DOM.create_text_node(document, "x"))

      Node.set_text_content(root, "")

      assert Node.child_nodes(root) == []
      assert Node.text_content(root) == ""
    end

    test "replaces a document fragment's children" do
      document = DOM.new()
      fragment = DOM.create_document_fragment(document)
      Node.append_child(fragment, DOM.create_element(document, "old"))

      Node.set_text_content(fragment, "frag")

      assert Node.text_content(fragment) == "frag"
      assert [text] = Node.child_nodes(fragment)
      assert Node.value(text) == "frag"
    end

    test "sets a text node's own value" do
      document = DOM.new()
      text = DOM.create_text_node(document, "old")

      Node.set_text_content(text, "new")

      assert Node.value(text) == "new"
      assert Node.text_content(text) == "new"
    end

    test "sets a comment node's own value" do
      document = DOM.new()
      comment = DOM.create_comment(document, "old")

      Node.set_text_content(comment, "new")

      assert Node.value(comment) == "new"
    end

    test "is a no-op on a document" do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      Node.append_child(document, root)

      Node.set_text_content(document, "ignored")

      assert Node.child_nodes(document) == [root]
    end

    test "is a no-op on a document type" do
      document = DOM.new()
      doctype = DOM.create_document_type(document, "html", "", "")

      Node.set_text_content(doctype, "ignored")

      assert Node.text_content(doctype) == nil
    end
  end
end
