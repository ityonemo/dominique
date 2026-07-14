defmodule Integration.Node.Element.AttrNodeTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  # The Attr node (nodeType 2) is a near-obsolete but standard part of the DOM.
  # Dominique models it as a `%DOM.Node{type: :attr}` handle whose `node_id` is the
  # `{owner_element_id, attribute_key}` pair — no backing NodeData record; every read
  # resolves through the owner element's attribute tuple, so the handle stays live.

  playwright do
    @link "https://dom.spec.whatwg.org/#interface-attr"

    @js """
    return await page.evaluate(() => {
      const el = document.createElement("div");
      el.setAttribute("id", "widget");
      el.setAttribute("class", "a b");

      const attr = el.getAttributeNode("id");
      const missing = el.getAttributeNode("nope");

      return {
        nodeType: attr.nodeType,
        nodeName: attr.nodeName,
        name: attr.name,
        localName: attr.localName,
        value: attr.value,
        prefix: attr.prefix,
        namespaceURI: attr.namespaceURI,
        ownerIsEl: attr.ownerElement === el,
        parentIsNull: attr.parentNode === null,
        childCount: attr.childNodes.length,
        missing: missing
      };
    });
    """

    test "getAttributeNode exposes an Attr node with the WHATWG shape", %{js: expected} do
      document = DOM.new()
      el = DOM.create_element(document, "div")
      Element.set_attribute(el, "id", "widget")
      Element.set_attribute(el, "class", "a b")

      attr = Element.get_attribute_node(el, "id")
      missing = Element.get_attribute_node(el, "nope")

      result = %{
        "nodeType" => Node.node_type(attr),
        "nodeName" => Node.node_name(attr),
        "name" => Node.attr_name(attr),
        "localName" => Node.attr_local_name(attr),
        "value" => Node.attr_value(attr),
        "prefix" => Node.attr_prefix(attr),
        "namespaceURI" => Node.attr_namespace_uri(attr),
        "ownerIsEl" => Node.is_same_node(Node.owner_element(attr), el),
        "parentIsNull" => Node.parent_node(attr) == nil,
        "childCount" => length(Node.child_nodes(attr)),
        "missing" => missing
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const el = document.createElement("div");
      el.setAttribute("data-x", "one");
      const attr = el.getAttributeNode("data-x");

      const before = attr.value;
      el.setAttribute("data-x", "two");   // mutate via the element
      const afterElementSet = attr.value; // the same attr handle sees it (live)

      return { before, afterElementSet };
    });
    """

    test "an Attr handle reads through to the owner element (live)", %{js: expected} do
      document = DOM.new()
      el = DOM.create_element(document, "div")
      Element.set_attribute(el, "data-x", "one")
      attr = Element.get_attribute_node(el, "data-x")

      before = Node.attr_value(attr)
      Element.set_attribute(el, "data-x", "two")
      after_element_set = Node.attr_value(attr)

      result = %{"before" => before, "afterElementSet" => after_element_set}

      assert result == expected
    end
  end
end
