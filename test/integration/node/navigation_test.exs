defmodule Integration.Node.NavigationTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node
  alias DOM.Node.Element

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-properties.html"
    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const first = document.createElement("first");
      const middle = document.createElement("middle");
      const last = document.createElement("last");
      parent.appendChild(first);
      parent.appendChild(middle);
      parent.appendChild(last);

      const name = node => node ? node.localName : null;

      return {
        firstChild: name(parent.firstChild),
        lastChild: name(parent.lastChild),
        firstChildOfLeaf: name(first.firstChild),
        middleNext: name(middle.nextSibling),
        middlePrev: name(middle.previousSibling),
        firstPrev: name(first.previousSibling),
        lastNext: name(last.nextSibling)
      };
    });
    """

    test "sibling and child navigation match the browser", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      first = DOM.create_element(document, "first")
      middle = DOM.create_element(document, "middle")
      last = DOM.create_element(document, "last")
      Node.append_child(parent, first)
      Node.append_child(parent, middle)
      Node.append_child(parent, last)

      result = %{
        "firstChild" => local_name(Node.first_child(parent)),
        "lastChild" => local_name(Node.last_child(parent)),
        "firstChildOfLeaf" => local_name(Node.first_child(first)),
        "middleNext" => local_name(Node.next_sibling(middle)),
        "middlePrev" => local_name(Node.previous_sibling(middle)),
        "firstPrev" => local_name(Node.previous_sibling(first)),
        "lastNext" => local_name(Node.next_sibling(last))
      }

      assert result == expected
    end
  end

  defp local_name(nil), do: nil
  defp local_name(node), do: Element.local_name(node)
end
