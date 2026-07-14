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

    @js """
    return await page.evaluate(() => {
      const el = document.createElement("div");
      el.setAttribute("data-x", "one");
      const attr = el.getAttributeNode("data-x");

      attr.value = "written";                  // write via the attr node...
      return { onElement: el.getAttribute("data-x") };  // ...shows up on the element
    });
    """

    test "writing an Attr's value writes through to the owner element", %{js: expected} do
      document = DOM.new()
      el = DOM.create_element(document, "div")
      Element.set_attribute(el, "data-x", "one")
      attr = Element.get_attribute_node(el, "data-x")

      Node.set_attr_value(attr, "written")
      result = %{"onElement" => Element.get_attribute(el, "data-x")}

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const el = document.createElement("div");
      const attr = document.createAttribute("title");   // unowned
      const initialValue = attr.value;                  // ""
      const initialOwner = attr.ownerElement;           // null
      attr.value = "hello";

      el.setAttributeNode(attr);                         // attach to element
      const onElement = el.getAttribute("title");
      const ownerNow = attr.ownerElement === el;

      return { initialValue, initialOwner, onElement, ownerNow };
    });
    """

    test "createAttribute makes an unowned Attr; setAttributeNode attaches it", %{js: expected} do
      document = DOM.new()
      el = DOM.create_element(document, "div")
      attr = DOM.create_attribute(document, "title")

      initial_value = Node.attr_value(attr)
      initial_owner = Node.owner_element(attr)
      attr = Node.set_attr_value(attr, "hello")

      Element.set_attribute_node(el, attr)
      on_element = Element.get_attribute(el, "title")

      owner_now =
        Node.is_same_node(Node.owner_element(Element.get_attribute_node(el, "title")), el)

      result = %{
        "initialValue" => initial_value,
        "initialOwner" => initial_owner,
        "onElement" => on_element,
        "ownerNow" => owner_now
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const el = document.createElement("div");
      el.setAttribute("data-x", "gone");
      const attr = el.getAttributeNode("data-x");

      const removed = el.removeAttributeNode(attr);
      return {
        stillOnElement: el.hasAttribute("data-x"),
        removedName: removed.name,
        removedValue: removed.value
      };
    });
    """

    test "removeAttributeNode detaches the attribute, returning the Attr", %{js: expected} do
      document = DOM.new()
      el = DOM.create_element(document, "div")
      Element.set_attribute(el, "data-x", "gone")
      attr = Element.get_attribute_node(el, "data-x")

      removed = Element.remove_attribute_node(el, attr)

      result = %{
        "stillOnElement" => Element.has_attribute(el, "data-x"),
        "removedName" => Node.attr_name(removed),
        "removedValue" => Node.attr_value(removed)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const el = document.createElement("div");
      el.setAttribute("data-x", "v");
      el.setAttribute("data-y", "v");
      const a = el.getAttributeNode("data-x");
      const b = el.getAttributeNode("data-x");
      const c = el.getAttributeNode("data-y");
      const clone = a.cloneNode();

      return {
        equalSame: a.isEqualNode(b),
        equalDiff: a.isEqualNode(c),
        cloneEqual: a.isEqualNode(clone),
        cloneName: clone.name,
        cloneValue: clone.value,
        cloneOwnerNull: clone.ownerElement === null
      };
    });
    """

    test "Attr isEqualNode compares name+value; cloneNode yields a detached copy", %{js: expected} do
      document = DOM.new()
      el = DOM.create_element(document, "div")
      Element.set_attribute(el, "data-x", "v")
      Element.set_attribute(el, "data-y", "v")
      a = Element.get_attribute_node(el, "data-x")
      b = Element.get_attribute_node(el, "data-x")
      c = Element.get_attribute_node(el, "data-y")
      clone = Node.clone_node(a)

      result = %{
        "equalSame" => Node.is_equal_node(a, b),
        "equalDiff" => Node.is_equal_node(a, c),
        "cloneEqual" => Node.is_equal_node(a, clone),
        "cloneName" => Node.attr_name(clone),
        "cloneValue" => Node.attr_value(clone),
        "cloneOwnerNull" => Node.owner_element(clone) == nil
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const XLINK = "http://www.w3.org/1999/xlink";
      const el = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      el.setAttributeNS(XLINK, "xlink:href", "#frag");

      const attr = el.getAttributeNodeNS(XLINK, "href");
      return {
        name: attr.name,
        localName: attr.localName,
        prefix: attr.prefix,
        namespaceURI: attr.namespaceURI,
        value: attr.value
      };
    });
    """

    test "getAttributeNodeNS returns a namespaced Attr with the triple-key parts", %{js: expected} do
      xlink = "http://www.w3.org/1999/xlink"
      document = DOM.new()
      el = DOM.create_element_ns(document, "http://www.w3.org/2000/svg", "svg")
      Element.set_attribute_ns(el, xlink, "xlink:href", "#frag")

      attr = Element.get_attribute_node_ns(el, xlink, "href")

      result = %{
        "name" => Node.attr_name(attr),
        "localName" => Node.attr_local_name(attr),
        "prefix" => Node.attr_prefix(attr),
        "namespaceURI" => Node.attr_namespace_uri(attr),
        "value" => Node.attr_value(attr)
      }

      assert result == expected
    end
  end
end
