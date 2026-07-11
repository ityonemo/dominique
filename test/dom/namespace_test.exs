defmodule DOM.NamespaceTest do
  use DOM.Case, async: true

  # T8a: the namespace API — createElementNS / getAttributeNS / setAttributeNS /
  # lookupPrefix / lookupNamespaceURI, plus the parsed-foreign-attribute round-trip.

  alias DOM.Element

  @svg "http://www.w3.org/2000/svg"
  @xlink "http://www.w3.org/1999/xlink"

  describe "parsed foreign attributes (representation)" do
    setup do
      doc = new_document("<svg><use xlink:href='#id' xml:lang='en' foo='bar'/></svg>")
      %{use: DOM.query_selector(doc, "use")}
    end

    test "get_attribute reads by qualified name; get_attribute_ns by (url, local)", %{use: use} do
      assert Element.get_attribute(use, "xlink:href") == "#id"
      assert Element.get_attribute_ns(use, @xlink, "href") == "#id"
      # wrong namespace -> nil
      assert Element.get_attribute_ns(use, "urn:other", "href") == nil
      # plain attribute is null-namespace
      assert Element.get_attribute_ns(use, nil, "foo") == "bar"
    end

    test "get_attribute_names returns qualified names; outerHTML round-trips with colons",
         %{use: use} do
      assert Element.get_attribute_names(use) == ["xlink:href", "xml:lang", "foo"]
      assert Element.outer_html(use) == ~s(<use xlink:href="#id" xml:lang="en" foo="bar"></use>)
    end
  end

  describe "create_element_ns" do
    test "maps a known url to the element namespace" do
      doc = new_document("<div></div>")
      rect = DOM.create_element_ns(doc, @svg, "rect")
      assert Element.namespace(rect) == :svg
      assert Element.local_name(rect) == "rect"
    end
  end

  describe "set_attribute_ns / get_attribute_ns" do
    test "stores a namespaced attribute retrievable by (url, local) and qualified name" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      Element.set_attribute_ns(d, @xlink, "xlink:href", "#z")
      assert Element.get_attribute_ns(d, @xlink, "href") == "#z"
      assert Element.get_attribute(d, "xlink:href") == "#z"
      assert Element.outer_html(d) == ~s(<div id="d" xlink:href="#z"></div>)
    end

    test "overwrite by (url, local) keeps the OLD prefix (spec-compliant), updates value" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      Element.set_attribute_ns(d, @xlink, "a:href", "1")
      Element.set_attribute_ns(d, @xlink, "b:href", "2")
      # one attribute (same (url, local)); prefix stays "a", value updated to "2"
      assert Element.get_attribute_ns(d, @xlink, "href") == "2"
      assert Element.get_attribute_names(d) == ["id", "a:href"]
    end

    test "same prefix+local but DIFFERENT url are two distinct attributes" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      Element.set_attribute_ns(d, "urn:A", "a:x", "1")
      Element.set_attribute_ns(d, "urn:B", "a:x", "2")

      assert Element.get_attribute_ns(d, "urn:A", "x") == "1"
      assert Element.get_attribute_ns(d, "urn:B", "x") == "2"
      assert Element.get_attribute_names(d) == ["id", "a:x", "a:x"]
    end
  end

  describe "lookup_namespace_uri / lookup_prefix" do
    # In an HTML document `xmlns:xlink` is a plain attribute, NOT a namespace
    # declaration (declarations are XML-only), so both browsers resolve these to nil.
    # Dominique models HTML documents, so lookups over a prefix return nil.
    test "a prefix lookup returns nil in an HTML document (no XML declarations)" do
      doc = new_document(~s(<div id='d' xmlns:xlink="#{@xlink}"></div>))
      d = DOM.query_selector(doc, "#d")

      assert Element.lookup_namespace_uri(d, "xlink") == nil
      assert Element.lookup_prefix(d, @xlink) == nil
    end

    test "an undeclared namespace resolves to nil" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")
      assert Element.lookup_namespace_uri(d, "nope") == nil
      assert Element.lookup_prefix(d, "urn:undeclared") == nil
    end
  end
end
