defmodule Integration.Node.OwnerDocumentTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-properties.html"
    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const element = xmlDocument.createElement("element");
      const text = xmlDocument.createTextNode("text");

      return {
        elementOwnsDocument: element.ownerDocument === xmlDocument,
        textOwnsDocument: text.ownerDocument === xmlDocument,
        documentOwner: xmlDocument.ownerDocument
      };
    });
    """

    test "ownerDocument points at the creating document", %{js: expected} do
      document = DOM.new()
      element = DOM.create_element(document, "element")
      text = DOM.create_text_node(document, "text")

      result = %{
        "elementOwnsDocument" => Node.owner_document(element).id == document.id,
        "textOwnsDocument" => Node.owner_document(text).id == document.id,
        "documentOwner" => Node.owner_document(document)
      }

      assert result == expected
    end
  end
end
