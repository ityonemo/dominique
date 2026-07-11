defmodule DOM.Shadow.InnerHtmlTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.Node
  alias DOM.ShadowRoot

  defp host_with_shadow(html \\ "<div id='d'>light</div>") do
    doc = new_document(html)
    d = DOM.query_selector(doc, "#d")
    {doc, d, Element.attach_shadow(d, :open)}
  end

  describe "DOM.ShadowRoot innerHTML / host / mode" do
    test "set_inner_html builds the shadow tree; inner_html reads it back" do
      {_doc, _d, shadow} = host_with_shadow()
      ShadowRoot.set_inner_html(shadow, "<p>shadow</p><span>x</span>")

      assert ShadowRoot.inner_html(shadow) == "<p>shadow</p><span>x</span>"
      assert Enum.map(Node.child_nodes(shadow), &Element.local_name/1) == ["p", "span"]
    end

    test "host and mode read back" do
      {_doc, d, shadow} = host_with_shadow()
      assert ShadowRoot.host(shadow).node_id == d.node_id
      assert ShadowRoot.mode(shadow) == :open
    end

    test "the host's outerHTML EXCLUDES the shadow tree" do
      {_doc, d, shadow} = host_with_shadow("<div id='d'>light text</div>")
      ShadowRoot.set_inner_html(shadow, "<p>shadow only</p>")

      # host serialization shows only its light children, never the shadow tree
      assert Element.outer_html(d) == "<div id=\"d\">light text</div>"
      assert Element.inner_html(d) == "light text"
    end

    test "a light-tree query does not descend into the shadow tree" do
      {doc, _d, shadow} = host_with_shadow("<div id='d'><em id='light'>L</em></div>")
      ShadowRoot.set_inner_html(shadow, "<em id='shadow'>S</em>")

      # querying the document (light tree) finds only the light <em>
      assert Enum.map(DOM.query_selector_all(doc, "em"), &Element.get_attribute(&1, "id")) ==
               ["light"]

      # querying the shadow root finds only the shadow <em>
      assert Enum.map(DOM.query_selector_all(shadow, "em"), &Element.get_attribute(&1, "id")) ==
               ["shadow"]
    end

    test "appending into the shadow root works via the generic mutators" do
      {doc, _d, shadow} = host_with_shadow()
      Node.append_child(shadow, DOM.create_element(doc, "article"))
      assert Enum.map(Node.child_nodes(shadow), &Element.local_name/1) == ["article"]
    end
  end
end
