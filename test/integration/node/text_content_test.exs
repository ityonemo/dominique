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

    @js """
    return await page.evaluate(() => {
      const root = document.createElement("root");
      root.appendChild(document.createElement("old"));
      root.appendChild(document.createTextNode("gone"));
      root.textContent = "fresh";

      const emptied = document.createElement("emptied");
      emptied.appendChild(document.createTextNode("x"));
      emptied.textContent = "";

      const text = document.createTextNode("old");
      text.textContent = "new";

      return {
        rootTextContent: root.textContent,
        rootChildCount: root.childNodes.length,
        rootChildIsText: root.firstChild.nodeType,
        emptiedChildCount: emptied.childNodes.length,
        textValue: text.textContent
      };
    });
    """

    test "setting textContent matches the browser", %{js: expected} do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      Node.append_child(root, DOM.create_element(document, "old"))
      Node.append_child(root, DOM.create_text_node(document, "gone"))
      Node.set_text_content(root, "fresh")

      emptied = DOM.create_element(document, "emptied")
      Node.append_child(emptied, DOM.create_text_node(document, "x"))
      Node.set_text_content(emptied, "")

      text = DOM.create_text_node(document, "old")
      Node.set_text_content(text, "new")

      [root_child] = Node.child_nodes(root)

      result = %{
        "rootTextContent" => Node.text_content(root),
        "rootChildCount" => root |> Node.child_nodes() |> length(),
        "rootChildIsText" => Node.node_type(root_child),
        "emptiedChildCount" => emptied |> Node.child_nodes() |> length(),
        "textValue" => Node.text_content(text)
      }

      assert result == expected
    end
  end
end
