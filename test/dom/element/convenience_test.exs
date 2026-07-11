defmodule DOM.Element.ConvenienceTest do
  use DOM.Case, async: true

  # T4: element convenience — closest, element-scoped get_elements_by_tag_name,
  # toggle_attribute, insert_adjacent_html/element/text.

  alias DOM.Element
  alias DOM.Node

  describe "closest" do
    setup do
      doc =
        new_document("""
        <div id='a' class='box'><section id='b'><span id='c'>x</span></section></div>
        """)

      %{doc: doc, c: DOM.query_selector(doc, "#c")}
    end

    test "returns the nearest ancestor-or-self matching the selector", %{c: c, doc: doc} do
      assert Element.closest(c, "section").node_id == DOM.query_selector(doc, "#b").node_id
      assert Element.closest(c, ".box").node_id == DOM.query_selector(doc, "#a").node_id
      # matches self
      assert Element.closest(c, "span").node_id == c.node_id
    end

    test "returns nil when nothing matches", %{c: c} do
      assert Element.closest(c, "table") == nil
    end
  end

  test "get_elements_by_tag_name scoped to an element" do
    doc = new_document("<div id='a'><p></p><span><p></p></span></div><p></p>")
    a = DOM.query_selector(doc, "#a")
    # only descendants of #a, not the sibling <p>
    assert length(Element.get_elements_by_tag_name(a, "p")) == 2
  end

  describe "toggle_attribute" do
    test "adds when absent, removes when present, returns the new presence" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      assert Element.toggle_attribute(d, "hidden") == true
      assert Element.has_attribute(d, "hidden")
      assert Element.get_attribute(d, "hidden") == ""

      assert Element.toggle_attribute(d, "hidden") == false
      refute Element.has_attribute(d, "hidden")
    end

    test "force true/false sets/clears unconditionally" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      assert Element.toggle_attribute(d, "x", true) == true
      assert Element.toggle_attribute(d, "x", true) == true
      assert Element.has_attribute(d, "x")

      assert Element.toggle_attribute(d, "x", false) == false
      refute Element.has_attribute(d, "x")
    end
  end

  describe "insert_adjacent_html" do
    setup do
      doc = new_document("<div id='p'><b id='t'>T</b></div>")
      %{doc: doc, p: DOM.query_selector(doc, "#p"), t: DOM.query_selector(doc, "#t")}
    end

    test "beforebegin / afterend insert as siblings of the element", %{t: t, p: p} do
      Element.insert_adjacent_html(t, "beforebegin", "<i>B</i>")
      Element.insert_adjacent_html(t, "afterend", "<i>A</i>")
      assert Element.inner_html(p) == "<i>B</i><b id=\"t\">T</b><i>A</i>"
    end

    test "afterbegin / beforeend insert as children of the element", %{t: t} do
      Element.insert_adjacent_html(t, "afterbegin", "<i>B</i>")
      Element.insert_adjacent_html(t, "beforeend", "<i>E</i>")
      assert Element.inner_html(t) == "<i>B</i>T<i>E</i>"
    end
  end

  test "insert_adjacent_element inserts and returns the node; insert_adjacent_text" do
    doc = new_document("<div id='p'><b id='t'>T</b></div>")
    p = DOM.query_selector(doc, "#p")
    t = DOM.query_selector(doc, "#t")

    u = DOM.create_element(doc, "u")
    returned = Element.insert_adjacent_element(t, "afterend", u)
    assert returned.node_id == u.node_id

    Element.insert_adjacent_text(t, "beforebegin", "hi")
    assert Node.text_content(p) =~ "hi"
    assert Element.get_attribute(Node.next_element_sibling(t), "id") == nil
  end
end
