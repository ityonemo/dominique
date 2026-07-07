defmodule Integration.Node.CloneNodeTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-cloneNode.html"
    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const child = document.createElement("child");
      parent.appendChild(child);
      child.appendChild(document.createTextNode("leaf"));

      const shallow = parent.cloneNode(false);
      const deep = parent.cloneNode(true);

      return {
        shallowName: shallow.localName,
        shallowSameNode: shallow === parent,
        shallowChildCount: shallow.childNodes.length,
        shallowParent: shallow.parentNode,
        deepChildren: Array.from(deep.childNodes, node => node.localName),
        deepText: deep.textContent,
        deepChildIsCopy: deep.firstChild !== child
      };
    });
    """

    test "cloneNode shallow and deep match the browser", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      child = DOM.create_element(document, "child")
      Node.append_child(parent, child)
      Node.append_child(child, DOM.create_text_node(document, "leaf"))

      shallow = Node.clone_node(parent, false)
      deep = Node.clone_node(parent, true)
      [deep_child] = Node.child_nodes(deep)

      result = %{
        "shallowName" => Element.local_name(shallow),
        "shallowSameNode" => shallow.id == parent.id,
        "shallowChildCount" => shallow |> Node.child_nodes() |> length(),
        "shallowParent" => Node.parent_node(shallow),
        "deepChildren" => deep |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "deepText" => Node.text_content(deep),
        "deepChildIsCopy" => deep_child.id != child.id
      }

      assert result == expected
    end
  end
end
