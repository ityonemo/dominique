defmodule Integration.Node.ReplaceChildTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node
  alias DOM.Node.Element

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-replaceChild.html"
    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const first = document.createElement("first");
      const old = document.createElement("old");
      const last = document.createElement("last");
      const replacement = document.createElement("replacement");
      parent.appendChild(first);
      parent.appendChild(old);
      parent.appendChild(last);

      const returned = parent.replaceChild(replacement, old);

      return {
        returnedName: returned.localName,
        children: Array.from(parent.childNodes, node => node.localName),
        replacementParent: replacement.parentNode.localName,
        oldParent: old.parentNode
      };
    });
    """

    test "replaceChild swaps the old child and returns it", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      first = DOM.create_element(document, "first")
      old = DOM.create_element(document, "old")
      last = DOM.create_element(document, "last")
      replacement = DOM.create_element(document, "replacement")
      Node.append_child(parent, first)
      Node.append_child(parent, old)
      Node.append_child(parent, last)

      returned = Node.replace_child(parent, replacement, old)

      result = %{
        "returnedName" => Element.local_name(returned),
        "children" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "replacementParent" => replacement |> Node.parent_node() |> Element.local_name(),
        "oldParent" => Node.parent_node(old)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const replacement = document.createElement("replacement");
      const stranger = document.createElement("stranger");

      let errorName = null;

      try {
        parent.replaceChild(replacement, stranger);
      } catch (error) {
        errorName = error.name;
      }

      return { errorName, replacementParent: replacement.parentNode };
    });
    """

    test "replaceChild rejects an old child that is not a child", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      replacement = DOM.create_element(document, "replacement")
      stranger = DOM.create_element(document, "stranger")

      result = %{
        "errorName" => error_name(fn -> Node.replace_child(parent, replacement, stranger) end),
        "replacementParent" => Node.parent_node(replacement)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const oldRoot = xmlDocument.createElement("old-root");
      const newRoot = xmlDocument.createElement("new-root");
      xmlDocument.appendChild(oldRoot);

      const returned = xmlDocument.replaceChild(newRoot, oldRoot);

      return {
        returnedName: returned.localName,
        documentChildren: Array.from(xmlDocument.childNodes, node => node.localName)
      };
    });
    """

    test "replaceChild swaps the document element", %{js: expected} do
      document = DOM.new()
      old_root = DOM.create_element(document, "old-root")
      new_root = DOM.create_element(document, "new-root")
      Node.append_child(document, old_root)

      returned = Node.replace_child(document, new_root, old_root)

      result = %{
        "returnedName" => Element.local_name(returned),
        "documentChildren" => document |> Node.child_nodes() |> Enum.map(&Element.local_name/1)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const old = document.createElement("old");
      const fragment = document.createDocumentFragment();
      fragment.appendChild(document.createElement("first"));
      fragment.appendChild(document.createElement("second"));
      parent.appendChild(old);

      parent.replaceChild(fragment, old);

      return {
        children: Array.from(parent.childNodes, node => node.localName),
        fragmentChildCount: fragment.childNodes.length
      };
    });
    """

    test "replaceChild inserts a fragment's children in place", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      old = DOM.create_element(document, "old")
      fragment = DOM.create_document_fragment(document)
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(parent, old)
      Node.append_child(fragment, first)
      Node.append_child(fragment, second)

      Node.replace_child(parent, fragment, old)

      result = %{
        "children" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "fragmentChildCount" => fragment |> Node.child_nodes() |> length()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const first = document.createElement("first");
      const second = document.createElement("second");
      parent.appendChild(first);
      parent.appendChild(second);

      const returned = parent.replaceChild(first, first);

      return {
        returnedName: returned.localName,
        children: Array.from(parent.childNodes, node => node.localName)
      };
    });
    """

    test "replaceChild with the same node leaves the tree unchanged", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(parent, first)
      Node.append_child(parent, second)

      returned = Node.replace_child(parent, first, first)

      result = %{
        "returnedName" => Element.local_name(returned),
        "children" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1)
      }

      assert result == expected
    end
  end

  defp error_name(operation) do
    operation.()
    nil
  rescue
    error -> error.__struct__ |> Module.split() |> List.last()
  end
end
