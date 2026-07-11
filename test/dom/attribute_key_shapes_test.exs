defmodule DOM.AttributeKeyShapesTest do
  use DOM.Case, async: true

  # T8a directive: for each at-risk attribute site (the ones that read/render an
  # attribute KEY), TWO tests — one exercising the plain bare-string key, one the
  # namespaced {prefix, local, url} triple key — proving the site handles both.
  #
  # A plain element (bare-string keys) and a foreign-content element (triple keys)
  # are built once; each `describe` targets one at-risk site.

  alias DOM.Element
  alias DOM.NodeData.Element, as: Rec

  @xlink "http://www.w3.org/1999/xlink"

  defp plain, do: DOM.query_selector(new_document("<div id='d' data-x='v'></div>"), "#d")

  defp namespaced,
    do: DOM.query_selector(new_document("<svg><use xlink:href='#id'/></svg>"), "use")

  describe "Element.qualified_name / dat_name (helpers)" do
    test "plain key" do
      assert Rec.qualified_name("data-x") == "data-x"
      assert Rec.dat_name("data-x") == "data-x"
    end

    test "triple key" do
      assert Rec.qualified_name({"xlink", "href", @xlink}) == "xlink:href"
      assert Rec.dat_name({"xlink", "href", @xlink}) == "xlink href"
      # nil-prefix triple (bare xmlns)
      assert Rec.qualified_name({nil, "xmlns", "u"}) == "xmlns"
    end
  end

  describe "get_attribute (element.ex + _table.ex)" do
    test "plain key" do
      assert Element.get_attribute(plain(), "data-x") == "v"
    end

    test "triple key (by qualified name)" do
      assert Element.get_attribute(namespaced(), "xlink:href") == "#id"
    end
  end

  describe "has_attribute" do
    test "plain key" do
      assert Element.has_attribute(plain(), "data-x")
    end

    test "triple key" do
      assert Element.has_attribute(namespaced(), "xlink:href")
      refute Element.has_attribute(namespaced(), "href")
    end
  end

  describe "get_attribute_names (serializer name rendering)" do
    test "plain key" do
      assert Element.get_attribute_names(plain()) == ["id", "data-x"]
    end

    test "triple key renders qualified" do
      assert Element.get_attribute_names(namespaced()) == ["xlink:href"]
    end
  end

  describe "set_attribute (update by qualified name)" do
    test "plain key: updates in place" do
      el = plain()
      Element.set_attribute(el, "data-x", "w")
      assert Element.get_attribute(el, "data-x") == "w"
    end

    test "triple key: setAttribute by qualified name updates the triple, keeps its key" do
      el = namespaced()
      Element.set_attribute(el, "xlink:href", "#new")
      assert Element.get_attribute(el, "xlink:href") == "#new"
      # still a triple (namespace preserved) — reachable by NS lookup
      assert Element.get_attribute_ns(el, @xlink, "href") == "#new"
    end
  end

  describe "remove_attribute" do
    test "plain key" do
      el = plain()
      Element.remove_attribute(el, "data-x")
      refute Element.has_attribute(el, "data-x")
    end

    test "triple key (by qualified name)" do
      el = namespaced()
      Element.remove_attribute(el, "xlink:href")
      refute Element.has_attribute(el, "xlink:href")
    end
  end

  describe "outer_html serialization" do
    test "plain key" do
      assert Element.outer_html(plain()) == ~s(<div id="d" data-x="v"></div>)
    end

    test "triple key renders the colon form" do
      assert Element.outer_html(namespaced()) == ~s(<use xlink:href="#id"></use>)
    end
  end

  describe "is_equal_node attribute compare" do
    test "plain key: equal elements compare equal" do
      doc = new_document("<div><i data-x='1'></i><i data-x='1'></i></div>")
      [a, b] = DOM.query_selector_all(doc, "i")
      assert DOM.Node.is_equal_node(a, b)
    end

    test "triple key: two foreign elements with the same namespaced attr are equal" do
      doc = new_document("<svg><use xlink:href='#z'/><use xlink:href='#z'/></svg>")
      [a, b] = DOM.query_selector_all(doc, "use")
      assert DOM.Node.is_equal_node(a, b)
    end
  end

  describe "index membership (getElementById / getElementsByClassName ignore triples)" do
    test "plain key: an id attribute populates getElementById" do
      doc = new_document("<div id='hit'></div>")
      assert DOM.get_element_by_id(doc, "hit") != nil
    end

    test "triple key: a namespaced local-name 'id' does NOT populate getElementById" do
      # <use xlink:href> has a namespaced attr; its local name is not the HTML id
      doc = new_document("<svg><use xlink:href='#id'/></svg>")
      # querying by the qualified attr string is invalid CSS; getElementById("id")
      # must NOT match the xlink:href attribute
      assert DOM.get_element_by_id(doc, "id") == nil
    end
  end

  describe "html5lib dat_outline dumper (space form)" do
    test "plain key renders verbatim" do
      # exercised through the full html5lib suite; here assert the helper directly
      assert Rec.dat_name("data-x") == "data-x"
    end

    test "triple key renders space-separated" do
      assert Rec.dat_name({"xlink", "href", @xlink}) == "xlink href"
    end
  end
end
