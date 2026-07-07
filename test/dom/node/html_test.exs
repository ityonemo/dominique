defmodule DOM.Node.HTMLTest do
  use ExUnit.Case, async: true

  alias DOM.Element
  alias DOM.Node

  describe "outer_html/1" do
    test "serializes an empty element" do
      document = DOM.new()
      div = DOM.create_element(document, "div")

      assert Element.outer_html(div) == "<div></div>"
    end

    test "serializes attributes in insertion order, double-quoted" do
      document = DOM.new()
      el = DOM.create_element(document, "a")
      DOM.Element.set_attribute(el, "href", "/x")
      DOM.Element.set_attribute(el, "id", "link")

      assert Element.outer_html(el) == ~s(<a href="/x" id="link"></a>)
    end

    test "serializes nested children" do
      document = DOM.new()
      ul = DOM.create_element(document, "ul")
      li = DOM.create_element(document, "li")
      Node.append_child(li, DOM.create_text_node(document, "one"))
      Node.append_child(ul, li)

      assert Element.outer_html(ul) == "<ul><li>one</li></ul>"
    end

    test "void elements get no end tag" do
      document = DOM.new()
      br = DOM.create_element(document, "br")

      assert Element.outer_html(br) == "<br>"
    end

    test "escapes text content (& < >)" do
      document = DOM.new()
      p = DOM.create_element(document, "p")
      Node.append_child(p, DOM.create_text_node(document, "a < b & c > d"))

      assert Element.outer_html(p) == "<p>a &lt; b &amp; c &gt; d</p>"
    end

    test "escapes attribute values (&, double-quote, and < >)" do
      document = DOM.new()
      el = DOM.create_element(document, "input")
      DOM.Element.set_attribute(el, "value", ~s(a & "b" < c > d))

      assert Element.outer_html(el) == ~s(<input value="a &amp; &quot;b&quot; &lt; c &gt; d">)
    end

    test "serializes comment children" do
      document = DOM.new()
      div = DOM.create_element(document, "div")
      Node.append_child(div, DOM.create_comment(document, "note"))

      assert Element.outer_html(div) == "<div><!--note--></div>"
    end

    test "does not escape raw-text element content" do
      document = DOM.new()
      style = DOM.create_element(document, "style")
      Node.append_child(style, DOM.create_text_node(document, "a > b & c"))

      assert Element.outer_html(style) == "<style>a > b & c</style>"
    end
  end

  describe "inner_html/1" do
    test "serializes children without the element's own tag" do
      document = DOM.new()
      div = DOM.create_element(document, "div")
      span = DOM.create_element(document, "span")
      Node.append_child(span, DOM.create_text_node(document, "hi"))
      Node.append_child(div, span)

      assert Element.inner_html(div) == "<span>hi</span>"
    end

    test "an empty element has empty inner html" do
      document = DOM.new()
      div = DOM.create_element(document, "div")

      assert Element.inner_html(div) == ""
    end
  end
end
