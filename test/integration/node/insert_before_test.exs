defmodule Integration.Node.InsertBeforeTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node
  alias DOM.Node.Element

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-insertBefore.html"
    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const first = document.createElement("first");
      const second = document.createElement("second");
      parent.appendChild(second);

      const inserted = parent.insertBefore(first, second);

      return {
        returnedName: inserted.localName,
        children: Array.from(parent.childNodes, node => node.localName),
        parentName: first.parentNode.localName
      };
    });
    """

    test "insertBefore inserts immediately before the reference child", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(parent, second)

      inserted = Node.insert_before(parent, first, second)

      result = %{
        "returnedName" => Element.local_name(inserted),
        "children" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "parentName" => first |> Node.parent_node() |> Element.local_name()
      }

      assert result == expected
    end
  end
end
