defmodule Integration.Node.Element.AttributeTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node.Element

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Element-setAttribute.html"
    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const element = xmlDocument.createElement("element");

      const missing = element.getAttribute("missing");
      element.setAttribute("id", "widget");
      element.setAttribute("class", "old");
      element.setAttribute("class", "new");

      return {
        missing,
        id: element.getAttribute("id"),
        overwritten: element.getAttribute("class"),
        hasId: element.hasAttribute("id"),
        hasMissing: element.hasAttribute("missing")
      };
    });
    """

    test "setAttribute and getAttribute round-trip like the browser", %{js: expected} do
      document = DOM.new()
      element = DOM.create_element(document, "element")

      missing = Element.get_attribute(element, "missing")
      Element.set_attribute(element, "id", "widget")
      Element.set_attribute(element, "class", "old")
      Element.set_attribute(element, "class", "new")

      result = %{
        "missing" => missing,
        "id" => Element.get_attribute(element, "id"),
        "overwritten" => Element.get_attribute(element, "class"),
        "hasId" => Element.has_attribute(element, "id"),
        "hasMissing" => Element.has_attribute(element, "missing")
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const element = xmlDocument.createElement("element");
      element.setAttribute("CamelCase", "kept");

      return {
        exact: element.getAttribute("CamelCase"),
        lowered: element.getAttribute("camelcase")
      };
    });
    """

    test "an XML document preserves attribute-name case", %{js: expected} do
      document = DOM.new()
      element = DOM.create_element(document, "element")
      Element.set_attribute(element, "CamelCase", "kept")

      result = %{
        "exact" => Element.get_attribute(element, "CamelCase"),
        "lowered" => Element.get_attribute(element, "camelcase")
      }

      assert result == expected
    end
  end
end
