defmodule Integration.Node.AppendChildTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node
  alias DOM.Node.Element

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Node-appendChild.html"
    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const first = document.createElement("first");
      const second = document.createElement("second");

      parent.appendChild(first);
      parent.appendChild(second);

      return Array.from(parent.childNodes, node => node.localName);
    });
    """

    test "appendChild preserves child order", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")

      assert parent
             |> tap(&Node.append_child(&1, first))
             |> tap(&Node.append_child(&1, second))
             |> Node.child_nodes()
             |> Enum.map(&Element.local_name/1) == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const child = document.createElement("child");

      parent.appendChild(child);

      return child.parentNode.localName;
    });
    """

    test "appendChild sets parentNode", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      child = DOM.create_element(document, "child")

      Node.append_child(parent, child)

      result = child |> Node.parent_node() |> Element.local_name()

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const oldParent = document.createElement("old-parent");
      const newParent = document.createElement("new-parent");
      const child = document.createElement("child");

      oldParent.appendChild(child);
      newParent.appendChild(child);

      return {
        oldParentChildren: Array.from(oldParent.childNodes, node => node.localName),
        newParentChildren: Array.from(newParent.childNodes, node => node.localName),
        parentNode: child.parentNode.localName
      };
    });
    """

    test "appendChild removes a node from its old parent", %{js: expected} do
      document = DOM.new()
      old_parent = DOM.create_element(document, "old-parent")
      new_parent = DOM.create_element(document, "new-parent")
      child = DOM.create_element(document, "child")

      Node.append_child(old_parent, child)
      Node.append_child(new_parent, child)

      result = %{
        "oldParentChildren" => local_names(old_parent),
        "newParentChildren" => local_names(new_parent),
        "parentNode" => child |> Node.parent_node() |> Element.local_name()
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
      parent.appendChild(first);

      return Array.from(parent.childNodes, node => node.localName);
    });
    """

    test "appendChild moves an existing child to the end", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")

      assert parent
             |> tap(&Node.append_child(&1, first))
             |> tap(&Node.append_child(&1, second))
             |> tap(&Node.append_child(&1, first))
             |> local_names() == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const child = document.createElement("child");
      parent.appendChild(child);

      let errorName = null;

      try {
        child.appendChild(parent);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        parentChildren: Array.from(parent.childNodes, node => node.localName),
        childChildren: Array.from(child.childNodes, node => node.localName),
        parentParent: parent.parentNode?.localName ?? null,
        childParent: child.parentNode?.localName ?? null
      };
    });
    """

    test "appendChild rejects an ancestor without changing the tree", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      child = DOM.create_element(document, "child")
      Node.append_child(parent, child)

      error_name = hierarchy_error_name(fn -> Node.append_child(child, parent) end)

      result = %{
        "errorName" => error_name,
        "parentChildren" => local_names(parent),
        "childChildren" => local_names(child),
        "parentParent" => parent |> Node.parent_node() |> local_name(),
        "childParent" => child |> Node.parent_node() |> local_name()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const element = xmlDocument.createElement("element");

      let errorName = null;

      try {
        element.appendChild(xmlDocument);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        elementChildren: Array.from(element.childNodes, node => node.localName),
        documentParent: xmlDocument.parentNode?.localName ?? null
      };
    });
    """

    test "appendChild rejects a document beneath an element", %{js: expected} do
      document = DOM.new()
      element = DOM.create_element(document, "element")

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(element, document) end),
        "elementChildren" => local_names(element),
        "documentParent" => document |> Node.parent_node() |> local_name()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const first = xmlDocument.createElement("first");
      const second = xmlDocument.createElement("second");
      xmlDocument.appendChild(first);

      let errorName = null;

      try {
        xmlDocument.appendChild(second);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        documentChildren: Array.from(xmlDocument.childNodes, node => node.localName),
        secondParent: second.parentNode?.localName ?? null
      };
    });
    """

    test "appendChild rejects a second document element", %{js: expected} do
      document = DOM.new()
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(document, first)

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(document, second) end),
        "documentChildren" => local_names(document),
        "secondParent" => second |> Node.parent_node() |> local_name()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const text = document.createTextNode("text");
      const child = document.createElement("child");

      let errorName = null;

      try {
        text.appendChild(child);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        textValue: text.nodeValue,
        childCount: text.childNodes.length,
        childParent: child.parentNode?.localName ?? null
      };
    });
    """

    test "appendChild rejects children on a text leaf", %{js: expected} do
      document = DOM.new()
      text = DOM.create_text_node(document, "text")
      child = DOM.create_element(document, "child")

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(text, child) end),
        "textValue" => Node.value(text),
        "childCount" => text |> Node.child_nodes() |> length(),
        "childParent" => child |> Node.parent_node() |> local_name()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const text = xmlDocument.createTextNode("text");

      let errorName = null;

      try {
        xmlDocument.appendChild(text);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        documentChildCount: xmlDocument.childNodes.length,
        textValue: text.nodeValue,
        hasParent: text.parentNode !== null
      };
    });
    """

    test "appendChild rejects a text child on a document", %{js: expected} do
      document = DOM.new()
      text = DOM.create_text_node(document, "text")

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(document, text) end),
        "documentChildCount" => document |> Node.child_nodes() |> length(),
        "textValue" => Node.value(text),
        "hasParent" => !!Node.parent_node(text)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const comment = document.createComment("comment");
      const child = document.createElement("child");

      let errorName = null;

      try {
        comment.appendChild(child);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        commentValue: comment.nodeValue,
        childCount: comment.childNodes.length,
        hasParent: child.parentNode !== null
      };
    });
    """

    test "appendChild rejects children on a comment leaf", %{js: expected} do
      document = DOM.new()
      comment = DOM.create_comment(document, "comment")
      child = DOM.create_element(document, "child")

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(comment, child) end),
        "commentValue" => Node.value(comment),
        "childCount" => comment |> Node.child_nodes() |> length(),
        "hasParent" => !!Node.parent_node(child)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const documentType = document.implementation.createDocumentType("html", "", "");
      const child = document.createElement("child");

      let errorName = null;

      try {
        documentType.appendChild(child);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        childCount: documentType.childNodes.length,
        hasParent: child.parentNode !== null
      };
    });
    """

    test "appendChild rejects children on a document type leaf", %{js: expected} do
      document = DOM.new()
      document_type = DOM.create_document_type(document, "html", "", "")
      child = DOM.create_element(document, "child")

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(document_type, child) end),
        "childCount" => document_type |> Node.child_nodes() |> length(),
        "hasParent" => !!Node.parent_node(child)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const documentType = document.implementation.createDocumentType("html", "", "");
      let errorName = null;

      try {
        parent.appendChild(documentType);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        parentChildCount: parent.childNodes.length,
        hasParent: documentType.parentNode !== null
      };
    });
    """

    test "appendChild rejects a document type beneath an element", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      document_type = DOM.create_document_type(document, "html", "", "")

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(parent, document_type) end),
        "parentChildCount" => parent |> Node.child_nodes() |> length(),
        "hasParent" => !!Node.parent_node(document_type)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const first = document.implementation.createDocumentType("first", "", "");
      const second = document.implementation.createDocumentType("second", "", "");
      xmlDocument.appendChild(first);
      let errorName = null;

      try {
        xmlDocument.appendChild(second);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        documentChildCount: xmlDocument.childNodes.length,
        hasParent: second.parentNode !== null
      };
    });
    """

    test "appendChild rejects a second document type", %{js: expected} do
      document = DOM.new()
      first = DOM.create_document_type(document, "first", "", "")
      second = DOM.create_document_type(document, "second", "", "")
      Node.append_child(document, first)

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(document, second) end),
        "documentChildCount" => document |> Node.child_nodes() |> length(),
        "hasParent" => !!Node.parent_node(second)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const element = xmlDocument.createElement("element");
      const documentType = document.implementation.createDocumentType("html", "", "");
      xmlDocument.appendChild(element);
      let errorName = null;

      try {
        xmlDocument.appendChild(documentType);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        documentChildCount: xmlDocument.childNodes.length,
        hasParent: documentType.parentNode !== null
      };
    });
    """

    test "appendChild rejects a document type after the document element", %{js: expected} do
      document = DOM.new()
      element = DOM.create_element(document, "element")
      document_type = DOM.create_document_type(document, "html", "", "")
      Node.append_child(document, element)

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(document, document_type) end),
        "documentChildCount" => document |> Node.child_nodes() |> length(),
        "hasParent" => !!Node.parent_node(document_type)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const source = document.implementation.createDocument(null, null);
      const destination = document.implementation.createDocument(null, null);
      const parent = destination.createElement("parent");
      const child = source.createElement("child");
      const grandchild = source.createElement("grandchild");
      child.appendChild(grandchild);
      destination.appendChild(parent);

      const appended = parent.appendChild(child);

      return {
        returnedName: appended.localName,
        parentChildren: Array.from(parent.childNodes, node => node.localName),
        childParent: child.parentNode.localName,
        grandchildParent: grandchild.parentNode.localName
      };
    });
    """

    test "appendChild transfers a subtree between documents", %{js: expected} do
      source = DOM.new()
      destination = DOM.new()
      parent = DOM.create_element(destination, "parent")
      child = DOM.create_element(source, "child")
      grandchild = DOM.create_element(source, "grandchild")
      Node.append_child(child, grandchild)
      Node.append_child(destination, parent)

      appended = Node.append_child(parent, child)
      [transferred_grandchild] = Node.child_nodes(appended)

      result = %{
        "returnedName" => Element.local_name(appended),
        "parentChildren" => local_names(parent),
        "childParent" => appended |> Node.parent_node() |> Element.local_name(),
        "grandchildParent" => transferred_grandchild |> Node.parent_node() |> Element.local_name()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const fragment = document.createDocumentFragment();
      fragment.appendChild(document.createElement("first"));
      fragment.appendChild(document.createElement("second"));

      const appended = parent.appendChild(fragment);

      return {
        returnedFragment: appended === fragment,
        parentChildren: Array.from(parent.childNodes, node => node.localName),
        fragmentChildCount: fragment.childNodes.length,
        firstParent: parent.firstChild.parentNode.localName,
        secondParent: parent.lastChild.parentNode.localName,
        fragmentHasParent: fragment.parentNode !== null
      };
    });
    """

    test "appendChild inserts and empties a document fragment", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      fragment = DOM.create_document_fragment(document)
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(fragment, first)
      Node.append_child(fragment, second)

      appended = Node.append_child(parent, fragment)
      [inserted_first, inserted_second] = Node.child_nodes(parent)

      result = %{
        "returnedFragment" => appended == fragment,
        "parentChildren" => local_names(parent),
        "fragmentChildCount" => fragment |> Node.child_nodes() |> length(),
        "firstParent" => inserted_first |> Node.parent_node() |> Element.local_name(),
        "secondParent" => inserted_second |> Node.parent_node() |> Element.local_name(),
        "fragmentHasParent" => !!Node.parent_node(fragment)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const fragment = xmlDocument.createDocumentFragment();
      const text = xmlDocument.createTextNode("text");
      fragment.appendChild(text);
      let errorName = null;

      try {
        xmlDocument.appendChild(fragment);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        documentChildCount: xmlDocument.childNodes.length,
        fragmentChildCount: fragment.childNodes.length,
        textParentIsFragment: text.parentNode === fragment
      };
    });
    """

    test "appendChild rejects a text-bearing fragment on a document", %{js: expected} do
      document = DOM.new()
      fragment = DOM.create_document_fragment(document)
      text = DOM.create_text_node(document, "text")
      Node.append_child(fragment, text)

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(document, fragment) end),
        "documentChildCount" => document |> Node.child_nodes() |> length(),
        "fragmentChildCount" => fragment |> Node.child_nodes() |> length(),
        "textParentIsFragment" => Node.parent_node(text) == fragment
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const fragment = xmlDocument.createDocumentFragment();
      fragment.appendChild(xmlDocument.createElement("first"));
      fragment.appendChild(xmlDocument.createElement("second"));
      let errorName = null;

      try {
        xmlDocument.appendChild(fragment);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        documentChildCount: xmlDocument.childNodes.length,
        fragmentChildCount: fragment.childNodes.length
      };
    });
    """

    test "appendChild rejects a multi-element fragment on a document", %{js: expected} do
      document = DOM.new()
      fragment = DOM.create_document_fragment(document)
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(fragment, first)
      Node.append_child(fragment, second)

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(document, fragment) end),
        "documentChildCount" => document |> Node.child_nodes() |> length(),
        "fragmentChildCount" => fragment |> Node.child_nodes() |> length()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const source = document.implementation.createDocument(null, null);
      const destination = document.implementation.createDocument(null, null);
      const parent = destination.createElement("parent");
      const fragment = source.createDocumentFragment();
      fragment.appendChild(source.createElement("first"));
      fragment.appendChild(source.createElement("second"));

      const appended = parent.appendChild(fragment);

      return {
        returnedFragment: appended === fragment,
        parentChildren: Array.from(parent.childNodes, node => node.localName),
        fragmentChildCount: fragment.childNodes.length,
        childrenBelongToDestination:
          Array.from(parent.childNodes, node => node.ownerDocument === destination)
      };
    });
    """

    test "appendChild transfers and inserts a fragment from another document", %{js: expected} do
      source = DOM.new()
      destination = DOM.new()
      parent = DOM.create_element(destination, "parent")
      fragment = DOM.create_document_fragment(source)
      first = DOM.create_element(source, "first")
      second = DOM.create_element(source, "second")
      Node.append_child(fragment, first)
      Node.append_child(fragment, second)

      appended = Node.append_child(parent, fragment)
      children = Node.child_nodes(parent)

      result = %{
        "returnedFragment" => appended.id == fragment.id,
        "parentChildren" => Enum.map(children, &Element.local_name/1),
        "fragmentChildCount" => appended |> Node.child_nodes() |> length(),
        "childrenBelongToDestination" => Enum.map(children, &(&1.server == destination.server))
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const source = document.implementation.createDocument(null, null);
      const destination = document.implementation.createDocument(null, null);
      const fragment = source.createDocumentFragment();
      fragment.appendChild(source.createElement("element"));

      const appended = destination.appendChild(fragment);

      return {
        returnedFragment: appended === fragment,
        documentElementName: destination.documentElement.localName,
        fragmentChildCount: fragment.childNodes.length,
        elementBelongsToDestination:
          destination.documentElement.ownerDocument === destination
      };
    });
    """

    test "appendChild transfers a valid fragment into another document", %{js: expected} do
      source = DOM.new()
      destination = DOM.new()
      fragment = DOM.create_document_fragment(source)
      element = DOM.create_element(source, "element")
      Node.append_child(fragment, element)

      appended = Node.append_child(destination, fragment)
      [transferred_element] = Node.child_nodes(destination)

      result = %{
        "returnedFragment" => appended.id == fragment.id,
        "documentElementName" => Element.local_name(transferred_element),
        "fragmentChildCount" => appended |> Node.child_nodes() |> length(),
        "elementBelongsToDestination" => transferred_element.server == destination.server
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const source = document.implementation.createDocument(null, null);
      const destination = document.implementation.createDocument(null, null);
      const fragment = source.createDocumentFragment();
      const text = source.createTextNode("text");
      fragment.appendChild(text);
      let errorName = null;

      try {
        destination.appendChild(fragment);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        destinationChildCount: destination.childNodes.length,
        fragmentChildCount: fragment.childNodes.length,
        textParentIsFragment: text.parentNode === fragment
      };
    });
    """

    test "appendChild preserves a rejected fragment in its source document", %{js: expected} do
      source = DOM.new()
      destination = DOM.new()
      fragment = DOM.create_document_fragment(source)
      text = DOM.create_text_node(source, "text")
      Node.append_child(fragment, text)

      result = %{
        "errorName" => hierarchy_error_name(fn -> Node.append_child(destination, fragment) end),
        "destinationChildCount" => destination |> Node.child_nodes() |> length(),
        "fragmentChildCount" => fragment |> Node.child_nodes() |> length(),
        "textParentIsFragment" => Node.parent_node(text) == fragment
      }

      assert result == expected
    end
  end

  defp local_names(parent) do
    parent
    |> Node.child_nodes()
    |> Enum.map(&Element.local_name/1)
  end

  defp local_name(nil), do: nil
  defp local_name(node), do: Element.local_name(node)

  defp hierarchy_error_name(operation) do
    operation.()
    nil
  rescue
    error -> error.__struct__ |> Module.split() |> List.last()
  end
end
