defmodule Integration.GetElementsByTagNameTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Element-getElementsByTagName.html"
    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const root = xmlDocument.createElement("root");
      const a1 = xmlDocument.createElement("a");
      const b = xmlDocument.createElement("b");
      const a2 = xmlDocument.createElement("a");
      xmlDocument.appendChild(root);
      root.appendChild(a1);
      root.appendChild(b);
      b.appendChild(a2);

      return {
        documentA: xmlDocument.getElementsByTagName("a").length,
        documentAll: Array.from(xmlDocument.getElementsByTagName("*"), n => n.localName),
        missing: xmlDocument.getElementsByTagName("missing").length,
        scopedA: Array.from(b.getElementsByTagName("a"), n => n.localName),
        scopedSelf: b.getElementsByTagName("b").length
      };
    });
    """

    test "getElementsByTagName matches the browser", %{js: expected} do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      a1 = DOM.create_element(document, "a")
      b = DOM.create_element(document, "b")
      a2 = DOM.create_element(document, "a")
      Node.append_child(document, root)
      Node.append_child(root, a1)
      Node.append_child(root, b)
      Node.append_child(b, a2)

      result = %{
        "documentA" => document |> DOM.get_elements_by_tag_name("a") |> length(),
        "documentAll" =>
          document |> DOM.get_elements_by_tag_name("*") |> Enum.map(&Element.local_name/1),
        "missing" => document |> DOM.get_elements_by_tag_name("missing") |> length(),
        "scopedA" => b |> DOM.get_elements_by_tag_name("a") |> Enum.map(&Element.local_name/1),
        "scopedSelf" => b |> DOM.get_elements_by_tag_name("b") |> length()
      }

      assert result == expected
    end
  end
end
