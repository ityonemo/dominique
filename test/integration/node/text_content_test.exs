defmodule Integration.Node.TextContentTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-textContent.html"
    @js """
    return await page.evaluate(() => {
      const root = document.createElement("root");
      const child = document.createElement("child");
      root.appendChild(document.createTextNode("a"));
      root.appendChild(child);
      child.appendChild(document.createTextNode("b"));
      root.appendChild(document.createComment("hidden"));
      root.appendChild(document.createTextNode("c"));

      const text = document.createTextNode("leaf");
      const comment = document.createComment("note");
      const empty = document.createElement("empty");

      return {
        elementTextContent: root.textContent,
        textTextContent: text.textContent,
        commentTextContent: comment.textContent,
        emptyTextContent: empty.textContent,
        documentTextContent: document.textContent
      };
    });
    """

    test "textContent matches the browser", %{js: expected} do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      child = DOM.create_element(document, "child")
      Node.append_child(root, DOM.create_text_node(document, "a"))
      Node.append_child(root, child)
      Node.append_child(child, DOM.create_text_node(document, "b"))
      Node.append_child(root, DOM.create_comment(document, "hidden"))
      Node.append_child(root, DOM.create_text_node(document, "c"))

      text = DOM.create_text_node(document, "leaf")
      comment = DOM.create_comment(document, "note")
      empty = DOM.create_element(document, "empty")

      result = %{
        "elementTextContent" => Node.text_content(root),
        "textTextContent" => Node.text_content(text),
        "commentTextContent" => Node.text_content(comment),
        "emptyTextContent" => Node.text_content(empty),
        "documentTextContent" => Node.text_content(document)
      }

      assert result == expected
    end
  end
end
