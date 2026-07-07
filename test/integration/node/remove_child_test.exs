defmodule Integration.Node.RemoveChildTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-removeChild.html"
    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const first = document.createElement("first");
      const second = document.createElement("second");
      parent.appendChild(first);
      parent.appendChild(second);

      const removed = parent.removeChild(first);

      return {
        returnedName: removed.localName,
        parentChildren: Array.from(parent.childNodes, node => node.localName),
        removedParent: removed.parentNode
      };
    });
    """

    test "removeChild detaches the child and returns it", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(parent, first)
      Node.append_child(parent, second)

      removed = Node.remove_child(parent, first)

      result = %{
        "returnedName" => Element.local_name(removed),
        "parentChildren" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "removedParent" => Node.parent_node(removed)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const stranger = document.createElement("stranger");

      let errorName = null;

      try {
        parent.removeChild(stranger);
      } catch (error) {
        errorName = error.name;
      }

      return { errorName, parentChildCount: parent.childNodes.length };
    });
    """

    test "removeChild rejects a node that is not a child", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      stranger = DOM.create_element(document, "stranger")

      result = %{
        "errorName" => error_name(fn -> Node.remove_child(parent, stranger) end),
        "parentChildCount" => parent |> Node.child_nodes() |> length()
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
