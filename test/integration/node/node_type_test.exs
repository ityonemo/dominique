defmodule Integration.Node.NodeTypeTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-properties.html"
    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const element = xmlDocument.createElement("div");
      const text = xmlDocument.createTextNode("t");
      const comment = xmlDocument.createComment("c");
      const doctype = document.implementation.createDocumentType("html", "", "");
      const fragment = xmlDocument.createDocumentFragment();

      const describe = node => ({ type: node.nodeType, name: node.nodeName });

      return {
        document: describe(xmlDocument),
        element: describe(element),
        text: describe(text),
        comment: describe(comment),
        doctype: describe(doctype),
        fragment: describe(fragment)
      };
    });
    """

    test "nodeType and nodeName match the browser", %{js: expected} do
      document = DOM.new()
      element = DOM.create_element(document, "div")
      text = DOM.create_text_node(document, "t")
      comment = DOM.create_comment(document, "c")
      doctype = DOM.create_document_type(document, "html", "", "")
      fragment = DOM.create_document_fragment(document)

      describe = fn node -> %{"type" => Node.node_type(node), "name" => Node.node_name(node)} end

      result = %{
        "document" => describe.(document),
        "element" => describe.(element),
        "text" => describe.(text),
        "comment" => describe.(comment),
        "doctype" => describe.(doctype),
        "fragment" => describe.(fragment)
      }

      assert result == expected
    end
  end
end
