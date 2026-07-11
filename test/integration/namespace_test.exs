defmodule Integration.NamespaceTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element

  @moduletag :integration

  @svg "http://www.w3.org/2000/svg"
  @xlink "http://www.w3.org/1999/xlink"

  playwright do
    @link "https://dom.spec.whatwg.org/#dom-element-getattributens"

    # Parsed foreign attributes + the NS API match the browser. (The overwrite-prefix
    # tiebreak is excluded — browsers disagree; it's unit-tested spec-compliant.)
    @js """
    return await page.evaluate(() => {
      const XLINK = "http://www.w3.org/1999/xlink";
      const SVG = "http://www.w3.org/2000/svg";
      const doc = new DOMParser().parseFromString(
        "<svg><use xlink:href='#id' xml:lang='en' foo='bar'/></svg>", "text/html");
      const use = doc.querySelector("use");
      const r = {};
      r.get_qualified = use.getAttribute("xlink:href");
      r.get_ns = use.getAttributeNS(XLINK, "href");
      r.get_ns_wrong = use.getAttributeNS("urn:other", "href");
      r.get_ns_plain = use.getAttributeNS(null, "foo");
      r.names = use.getAttributeNames();
      r.outer = use.querySelector ? doc.querySelector("use").outerHTML : null;

      // createElementNS + setAttributeNS
      const rect = doc.createElementNS(SVG, "rect");
      r.rect_local = rect.localName;
      const el = doc.createElement("div");
      el.setAttributeNS(XLINK, "xlink:href", "#z");
      r.set_get_ns = el.getAttributeNS(XLINK, "href");
      r.set_get_qual = el.getAttribute("xlink:href");
      r.set_outer = el.outerHTML;

      // same prefix+local, different url -> two distinct attributes
      const el2 = doc.createElement("div");
      el2.setAttributeNS("urn:A", "a:x", "1");
      el2.setAttributeNS("urn:B", "a:x", "2");
      r.dual_names = el2.getAttributeNames();
      r.dual_A = el2.getAttributeNS("urn:A", "x");
      r.dual_B = el2.getAttributeNS("urn:B", "x");
      return r;
    });
    """

    test "foreign attributes + NS API match the browser", %{js: expected} do
      doc = DOM.new("<svg><use xlink:href='#id' xml:lang='en' foo='bar'/></svg>")
      use = DOM.query_selector(doc, "use")

      rect = DOM.create_element_ns(doc, @svg, "rect")

      el = DOM.create_element(doc, "div")
      Element.set_attribute_ns(el, @xlink, "xlink:href", "#z")

      el2 = DOM.create_element(doc, "div")
      Element.set_attribute_ns(el2, "urn:A", "a:x", "1")
      Element.set_attribute_ns(el2, "urn:B", "a:x", "2")

      result = %{
        "get_qualified" => Element.get_attribute(use, "xlink:href"),
        "get_ns" => Element.get_attribute_ns(use, @xlink, "href"),
        "get_ns_wrong" => Element.get_attribute_ns(use, "urn:other", "href"),
        "get_ns_plain" => Element.get_attribute_ns(use, nil, "foo"),
        "names" => Element.get_attribute_names(use),
        "outer" => Element.outer_html(use),
        "rect_local" => Element.local_name(rect),
        "set_get_ns" => Element.get_attribute_ns(el, @xlink, "href"),
        "set_get_qual" => Element.get_attribute(el, "xlink:href"),
        "set_outer" => Element.outer_html(el),
        "dual_names" => Element.get_attribute_names(el2),
        "dual_A" => Element.get_attribute_ns(el2, "urn:A", "x"),
        "dual_B" => Element.get_attribute_ns(el2, "urn:B", "x")
      }

      assert result == expected
    end
  end
end
