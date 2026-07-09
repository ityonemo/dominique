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

  describe "set_inner_html/2" do
    test "parses the HTML and replaces the element's children" do
      document = DOM.new()
      div = DOM.create_element(document, "div")
      Element.set_inner_html(div, "<span>hi</span><b>x</b>")

      assert Element.inner_html(div) == "<span>hi</span><b>x</b>"
    end

    test "discards the element's previous children" do
      document = DOM.new()
      div = DOM.create_element(document, "div")
      Node.append_child(div, DOM.create_text_node(document, "old"))
      Element.set_inner_html(div, "<p>new</p>")

      assert Element.inner_html(div) == "<p>new</p>"
    end

    test "setting empty string clears the children" do
      document = DOM.new()
      div = DOM.create_element(document, "div")
      Node.append_child(div, DOM.create_element(document, "span"))
      Element.set_inner_html(div, "")

      assert Element.inner_html(div) == ""
    end

    test "parses in the element's own context (table repairs)" do
      document = DOM.new()
      table = DOM.create_element(document, "table")
      # A bare <tr> in a table context is wrapped in an implied <tbody>.
      Element.set_inner_html(table, "<tr><td>c</td></tr>")

      assert Element.inner_html(table) == "<tbody><tr><td>c</td></tr></tbody>"
    end

    test "the parsed children belong to the element's document" do
      document = DOM.new()
      div = DOM.create_element(document, "div")
      Node.append_child(document, div)
      Element.set_inner_html(div, "<a id=x>link</a>")

      assert DOM.query_selector(document, "#x") != nil
    end
  end

  describe "set_outer_html/2" do
    test "replaces the element itself with the parsed nodes" do
      document = DOM.new()
      root = DOM.create_element(document, "div")
      target = DOM.create_element(document, "span")
      Node.append_child(root, DOM.create_text_node(document, "a"))
      Node.append_child(root, target)
      Node.append_child(root, DOM.create_text_node(document, "b"))

      Element.set_outer_html(target, "<p>x</p><em>y</em>")

      assert Element.inner_html(root) == "a<p>x</p><em>y</em>b"
    end

    test "parses in the parent's context (a <tr> parent keeps table repairs sane)" do
      document = DOM.new()
      root = DOM.create_element(document, "div")
      target = DOM.create_element(document, "span")
      Node.append_child(root, target)

      Element.set_outer_html(target, "<b>z</b>")

      assert Element.inner_html(root) == "<b>z</b>"
    end

    test "raises when the element has no parent" do
      document = DOM.new()
      orphan = DOM.create_element(document, "div")

      assert_raise DOM.NoModificationAllowedError, fn ->
        Element.set_outer_html(orphan, "<p>x</p>")
      end
    end
  end
end
