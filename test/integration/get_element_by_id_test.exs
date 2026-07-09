defmodule Integration.GetElementByIdTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Document-getElementById.html"
    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const root = xmlDocument.createElement("root");
      xmlDocument.appendChild(root);

      const first = xmlDocument.createElement("first");
      const second = xmlDocument.createElement("second");
      first.setAttribute("id", "dup");
      second.setAttribute("id", "dup");
      const only = xmlDocument.createElement("only");
      only.setAttribute("id", "unique");
      root.appendChild(first);
      root.appendChild(second);
      root.appendChild(only);

      const found = xmlDocument.getElementById("dup");
      return {
        firstWins: found === first,
        uniqueName: xmlDocument.getElementById("unique").localName,
        missing: xmlDocument.getElementById("nope")
      };
    });
    """

    test "getElementById matches the browser", %{js: expected} do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      Node.append_child(document, root)

      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Element.set_attribute(first, "id", "dup")
      Element.set_attribute(second, "id", "dup")
      only = DOM.create_element(document, "only")
      Element.set_attribute(only, "id", "unique")
      Node.append_child(root, first)
      Node.append_child(root, second)
      Node.append_child(root, only)

      found = DOM.get_element_by_id(document, "dup")

      result = %{
        "firstWins" => found.node_id == first.node_id,
        "uniqueName" => document |> DOM.get_element_by_id("unique") |> Element.local_name(),
        "missing" => DOM.get_element_by_id(document, "nope")
      }

      assert result == expected
    end
  end
end
