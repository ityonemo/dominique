defmodule DOM.DocumentAccessorsTest do
  use DOM.Case, async: true

  # T7: document accessors (document_element / body / head / get_elements_by_name)
  # and adopt_node / import_node.

  alias DOM.Element
  alias DOM.Node

  describe "document accessors" do
    test "document_element / body / head" do
      doc = new_document("<p>hi</p>")

      assert Element.local_name(DOM.document_element(doc)) == "html"
      assert Element.local_name(DOM.body(doc)) == "body"
      assert Element.local_name(DOM.head(doc)) == "head"
    end

    test "get_elements_by_name matches the name attribute" do
      doc = new_document("<form><input name='q'><input name='q'><input name='r'></form>")
      assert length(DOM.get_elements_by_name(doc, "q")) == 2
      assert length(DOM.get_elements_by_name(doc, "r")) == 1
      assert DOM.get_elements_by_name(doc, "none") == []
    end
  end

  describe "adopt_node" do
    test "moves a node into the document, detaching it from its source" do
      src = new_document("<div id='s'><span id='x'>hi</span></div>")
      dst = new_document("<div id='d'></div>")
      x = DOM.query_selector(src, "#x")

      adopted = DOM.adopt_node(dst, x)

      # gone from the source tree
      assert DOM.query_selector(src, "#x") == nil
      # detached, but owned by dst now
      assert Node.parent_node(adopted) == nil
      assert Node.owner_document(adopted).node_id == dst.node_id
      assert Element.outer_html(adopted) == "<span id=\"x\">hi</span>"

      # and it can be inserted into dst
      d = DOM.query_selector(dst, "#d")
      Node.append_child(d, adopted)
      assert Element.inner_html(d) == "<span id=\"x\">hi</span>"
    end
  end

  describe "import_node" do
    test "copies a node into the document, leaving the source intact" do
      src = new_document("<a id='imp'><b>deep</b></a>")
      dst = new_document("<div id='d'></div>")
      a = DOM.query_selector(src, "#imp")

      shallow = DOM.import_node(dst, a, false)
      deep = DOM.import_node(dst, a, true)

      assert Element.outer_html(shallow) == "<a id=\"imp\"></a>"
      assert Element.outer_html(deep) == "<a id=\"imp\"><b>deep</b></a>"
      assert Node.owner_document(deep).node_id == dst.node_id

      # source is untouched
      assert DOM.query_selector(src, "#imp") != nil
      assert Element.outer_html(a) == "<a id=\"imp\"><b>deep</b></a>"
    end
  end
end
