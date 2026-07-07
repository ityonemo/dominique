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
end
