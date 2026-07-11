defmodule DOM.Shadow.GetRootNodeTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node
  alias DOM.ShadowRoot

  describe "get_root_node" do
    test "a light-tree node's root is the document" do
      doc = new_document("<div id='d'><p id='p'>x</p></div>")
      p = DOM.query_selector(doc, "#p")

      assert Node.get_root_node(p).node_id == doc.node_id
      assert Node.get_root_node(p, true).node_id == doc.node_id
    end

    test "a shadow-tree node's non-composed root is the shadow root" do
      doc = new_document("<div id='host'></div>")
      host = DOM.query_selector(doc, "#host")
      shadow = Element.attach_shadow(host, :open)
      ShadowRoot.set_inner_html(shadow, "<span id='inner'>x</span>")
      inner = DOM.query_selector(shadow, "#inner")

      assert Node.get_root_node(inner).node_id == shadow.node_id
      assert Node.get_root_node(inner).type == :shadow_root
    end

    test "a shadow-tree node's composed root crosses to the document" do
      doc = new_document("<div id='host'></div>")
      host = DOM.query_selector(doc, "#host")
      shadow = Element.attach_shadow(host, :open)
      ShadowRoot.set_inner_html(shadow, "<span id='inner'>x</span>")
      inner = DOM.query_selector(shadow, "#inner")

      assert Node.get_root_node(inner, true).node_id == doc.node_id
    end

    test "the shadow root itself: non-composed is itself, composed is the document" do
      doc = new_document("<div id='host'></div>")
      host = DOM.query_selector(doc, "#host")
      shadow = Element.attach_shadow(host, :open)

      assert Node.get_root_node(shadow).node_id == shadow.node_id
      assert Node.get_root_node(shadow, true).node_id == doc.node_id
    end

    test "nested shadow trees: composed root walks up through every host" do
      doc = new_document("<div id='outer'></div>")
      outer = DOM.query_selector(doc, "#outer")
      outer_shadow = Element.attach_shadow(outer, :open)
      ShadowRoot.set_inner_html(outer_shadow, "<div id='mid'></div>")
      mid = DOM.query_selector(outer_shadow, "#mid")
      mid_shadow = Element.attach_shadow(mid, :open)
      ShadowRoot.set_inner_html(mid_shadow, "<span id='deep'>x</span>")
      deep = DOM.query_selector(mid_shadow, "#deep")

      # non-composed stops at the innermost shadow root
      assert Node.get_root_node(deep).node_id == mid_shadow.node_id
      # composed crosses both shadow boundaries to the document
      assert Node.get_root_node(deep, true).node_id == doc.node_id
    end
  end
end
