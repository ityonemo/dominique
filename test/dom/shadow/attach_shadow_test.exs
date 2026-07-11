defmodule DOM.Shadow.AttachShadowTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node

  describe "attach_shadow / shadow_root" do
    test "attach_shadow returns a shadow-root handle" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      shadow = Element.attach_shadow(d, :open)
      assert shadow.type == :shadow_root
      assert Node.node_type(shadow) == 11
      assert Node.node_name(shadow) == "#document-fragment"
    end

    test "shadow_root returns the open shadow root of the host" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")
      shadow = Element.attach_shadow(d, :open)

      assert Element.shadow_root(d).node_id == shadow.node_id
    end

    test "shadow_root returns nil for a closed shadow root" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")
      _shadow = Element.attach_shadow(d, :closed)

      assert Element.shadow_root(d) == nil
    end

    test "shadow_root is nil for an element with no shadow" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")
      assert Element.shadow_root(d) == nil
    end

    test "attaching a shadow root twice raises NotSupportedError" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")
      Element.attach_shadow(d, :open)

      assert_raise DOM.NotSupportedError, fn -> Element.attach_shadow(d, :open) end
    end

    test "attaching to an ineligible element raises NotSupportedError" do
      doc = new_document("<table id='t'></table>")
      t = DOM.query_selector(doc, "#t")
      assert_raise DOM.NotSupportedError, fn -> Element.attach_shadow(t, :open) end
    end

    test "the shadow root is a valid detached root (consistency holds)" do
      # DOM.Case's on_exit runs check_consistency! — attaching a shadow root
      # (an extra detached root) must not break it.
      doc = new_document("<section id='s'></section>")
      s = DOM.query_selector(doc, "#s")
      shadow = Element.attach_shadow(s, :open)
      # append a child into the shadow tree
      Node.append_child(shadow, DOM.create_element(doc, "p"))
      assert Enum.map(Node.child_nodes(shadow), &Element.local_name/1) == ["p"]
    end
  end
end
