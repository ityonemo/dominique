defmodule Integration.Node.HTMLTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/domparsing/innerhtml-01.html"
    @js """
    return await page.evaluate(() => {
      const root = document.createElement("div");
      root.setAttribute("id", "root");
      root.setAttribute("data-x", 'a & "b" < c');

      const p = document.createElement("p");
      p.appendChild(document.createTextNode("a < b & c > d"));
      root.appendChild(p);

      root.appendChild(document.createComment("note"));

      const br = document.createElement("br");
      root.appendChild(br);

      const style = document.createElement("style");
      style.appendChild(document.createTextNode(".x > .y { color: red }"));
      root.appendChild(style);

      return { outer: root.outerHTML, inner: root.innerHTML };
    });
    """

    test "outerHTML and innerHTML match the browser", %{js: expected} do
      document = DOM.new()
      root = DOM.create_element(document, "div")
      Element.set_attribute(root, "id", "root")
      Element.set_attribute(root, "data-x", ~s(a & "b" < c))

      p = DOM.create_element(document, "p")
      Node.append_child(p, DOM.create_text_node(document, "a < b & c > d"))
      Node.append_child(root, p)

      Node.append_child(root, DOM.create_comment(document, "note"))
      Node.append_child(root, DOM.create_element(document, "br"))

      style = DOM.create_element(document, "style")
      Node.append_child(style, DOM.create_text_node(document, ".x > .y { color: red }"))
      Node.append_child(root, style)

      result = %{"outer" => Element.outer_html(root), "inner" => Element.inner_html(root)}

      assert result == expected
    end
  end

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/domparsing/innerhtml-01.html"

    # innerHTML setter: assign markup, read it back. Covers ordinary nesting +
    # comment, and the table-context fragment repair (a bare <tr> gains an implied
    # <tbody>) — the setter parses in the element's own context.
    @js """
    return await page.evaluate(() => {
      const div = document.createElement("div");
      div.innerHTML = "<span>hi</span><b>x</b><!--n-->";
      const table = document.createElement("table");
      table.innerHTML = "<tr><td>c</td></tr>";
      return { div: div.innerHTML, table: table.innerHTML };
    });
    """

    test "innerHTML setter round-trips like the browser", %{js: expected} do
      document = DOM.new()

      div = DOM.create_element(document, "div")
      Element.set_inner_html(div, "<span>hi</span><b>x</b><!--n-->")

      table = DOM.create_element(document, "table")
      Element.set_inner_html(table, "<tr><td>c</td></tr>")

      result = %{"div" => Element.inner_html(div), "table" => Element.inner_html(table)}

      assert result == expected
    end
  end

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/domparsing/outerhtml-01.html"

    # outerHTML setter: replace the element itself with parsed markup, in the
    # PARENT's context. Read the parent's innerHTML back to observe the result.
    @js """
    return await page.evaluate(() => {
      const root = document.createElement("div");
      root.innerHTML = "a<span>t</span>b";
      root.querySelector("span").outerHTML = "<p>x</p><em>y</em>";
      return root.innerHTML;
    });
    """

    test "outerHTML setter round-trips like the browser", %{js: expected} do
      document = DOM.new()
      root = DOM.create_element(document, "div")
      Element.set_inner_html(root, "a<span>t</span>b")

      Element.set_outer_html(DOM.Element.query_selector(root, "span"), "<p>x</p><em>y</em>")

      assert Element.inner_html(root) == expected
    end
  end
end
