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

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const first = document.createElement("first");
      const second = document.createElement("second");
      parent.appendChild(first);

      const inserted = parent.insertBefore(second, null);

      return {
        returnedName: inserted.localName,
        children: Array.from(parent.childNodes, node => node.localName),
        parentName: second.parentNode.localName
      };
    });
    """

    test "insertBefore appends when the reference child is null", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(parent, first)

      inserted = Node.insert_before(parent, second, nil)

      result = %{
        "returnedName" => Element.local_name(inserted),
        "children" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "parentName" => second |> Node.parent_node() |> Element.local_name()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const child = document.createElement("child");
      const stranger = document.createElement("stranger");

      let errorName = null;

      try {
        parent.insertBefore(child, stranger);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        parentChildren: Array.from(parent.childNodes, node => node.localName),
        childParent: child.parentNode?.localName ?? null
      };
    });
    """

    test "insertBefore rejects a reference child from another parent", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      child = DOM.create_element(document, "child")
      stranger = DOM.create_element(document, "stranger")

      result = %{
        "errorName" => error_name(fn -> Node.insert_before(parent, child, stranger) end),
        "parentChildren" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "childParent" => child |> Node.parent_node() |> local_name()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const reference = document.createElement("reference");
      const fragment = document.createDocumentFragment();
      fragment.appendChild(document.createElement("first"));
      fragment.appendChild(document.createElement("second"));
      parent.appendChild(reference);

      const returned = parent.insertBefore(fragment, reference);

      return {
        returnedFragment: returned === fragment,
        parentChildren: Array.from(parent.childNodes, node => node.localName),
        fragmentChildCount: fragment.childNodes.length,
        firstParent: parent.firstChild.parentNode.localName
      };
    });
    """

    test "insertBefore inserts a fragment's children before the reference child", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      reference = DOM.create_element(document, "reference")
      fragment = DOM.create_document_fragment(document)
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(parent, reference)
      Node.append_child(fragment, first)
      Node.append_child(fragment, second)

      returned = Node.insert_before(parent, fragment, reference)
      [inserted_first | _] = Node.child_nodes(parent)

      result = %{
        "returnedFragment" => returned.id == fragment.id,
        "parentChildren" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "fragmentChildCount" => fragment |> Node.child_nodes() |> length(),
        "firstParent" => inserted_first |> Node.parent_node() |> Element.local_name()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const source = document.implementation.createDocument(null, null);
      const destination = document.implementation.createDocument(null, null);
      const parent = destination.createElement("parent");
      const reference = destination.createElement("reference");
      const child = source.createElement("child");
      destination.appendChild(parent);
      parent.appendChild(reference);

      const inserted = parent.insertBefore(child, reference);

      return {
        returnedName: inserted.localName,
        parentChildren: Array.from(parent.childNodes, node => node.localName),
        childParent: child.parentNode.localName,
        childBelongsToDestination: child.ownerDocument === destination
      };
    });
    """

    test "insertBefore adopts a child from another document", %{js: expected} do
      source = DOM.new()
      destination = DOM.new()
      parent = DOM.create_element(destination, "parent")
      reference = DOM.create_element(destination, "reference")
      child = DOM.create_element(source, "child")
      Node.append_child(destination, parent)
      Node.append_child(parent, reference)

      inserted = Node.insert_before(parent, child, reference)

      result = %{
        "returnedName" => Element.local_name(inserted),
        "parentChildren" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "childParent" => inserted |> Node.parent_node() |> Element.local_name(),
        "childBelongsToDestination" => inserted.server == destination.server
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const text = document.createTextNode("text");
      const reference = document.createTextNode("reference");
      const child = document.createElement("child");

      let errorName = null;

      try {
        text.insertBefore(child, reference);
      } catch (error) {
        errorName = error.name;
      }

      return { errorName, hasParent: child.parentNode !== null };
    });
    """

    test "insertBefore rejects a child on a text leaf", %{js: expected} do
      document = DOM.new()
      text = DOM.create_text_node(document, "text")
      child = DOM.create_element(document, "child")

      result = %{
        "errorName" => error_name(fn -> Node.insert_before(text, child, text) end),
        "hasParent" => !!Node.parent_node(child)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const child = document.createElement("child");
      parent.appendChild(child);

      let errorName = null;

      try {
        child.insertBefore(parent, null);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        childChildren: Array.from(child.childNodes, node => node.localName),
        parentParent: parent.parentNode?.localName ?? null
      };
    });
    """

    test "insertBefore rejects an inclusive ancestor", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      child = DOM.create_element(document, "child")
      Node.append_child(parent, child)

      result = %{
        "errorName" => error_name(fn -> Node.insert_before(child, parent, nil) end),
        "childChildren" => child |> Node.child_nodes() |> Enum.map(&Element.local_name/1),
        "parentParent" => parent |> Node.parent_node() |> local_name()
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
        xmlDocument.insertBefore(second, first);
      } catch (error) {
        errorName = error.name;
      }

      return {
        errorName,
        documentChildren: Array.from(xmlDocument.childNodes, node => node.localName)
      };
    });
    """

    test "insertBefore rejects a second document element", %{js: expected} do
      document = DOM.new()
      first = DOM.create_element(document, "first")
      second = DOM.create_element(document, "second")
      Node.append_child(document, first)

      result = %{
        "errorName" => error_name(fn -> Node.insert_before(document, second, first) end),
        "documentChildren" => document |> Node.child_nodes() |> Enum.map(&Element.local_name/1)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const doctype = document.implementation.createDocumentType("html", "", "");
      const reference = document.createElement("reference");
      parent.appendChild(reference);

      let errorName = null;

      try {
        parent.insertBefore(doctype, reference);
      } catch (error) {
        errorName = error.name;
      }

      return { errorName, parentChildCount: parent.childNodes.length };
    });
    """

    test "insertBefore rejects a doctype beneath an element", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      doctype = DOM.create_document_type(document, "html", "", "")
      reference = DOM.create_element(document, "reference")
      Node.append_child(parent, reference)

      result = %{
        "errorName" => error_name(fn -> Node.insert_before(parent, doctype, reference) end),
        "parentChildCount" => parent |> Node.child_nodes() |> length()
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const parent = document.createElement("parent");
      const child = document.createElement("child");
      parent.appendChild(child);

      const returned = parent.insertBefore(child, child);

      return {
        returnedName: returned.localName,
        children: Array.from(parent.childNodes, node => node.localName)
      };
    });
    """

    test "insertBefore before itself leaves the tree unchanged", %{js: expected} do
      document = DOM.new()
      parent = DOM.create_element(document, "parent")
      child = DOM.create_element(document, "child")
      Node.append_child(parent, child)

      returned = Node.insert_before(parent, child, child)

      result = %{
        "returnedName" => Element.local_name(returned),
        "children" => parent |> Node.child_nodes() |> Enum.map(&Element.local_name/1)
      }

      assert result == expected
    end
  end

  defp local_name(nil), do: nil
  defp local_name(node), do: Element.local_name(node)

  defp error_name(operation) do
    operation.()
    nil
  rescue
    error -> error.__struct__ |> Module.split() |> List.last()
  end
end
