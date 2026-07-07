defmodule Integration.GetElementsByClassNameTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/blob/master/dom/nodes/Element-getElementsByClassName-null-undef.html"
    @js """
    return await page.evaluate(() => {
      const xmlDocument = document.implementation.createDocument(null, null);
      const root = xmlDocument.createElement("root");
      xmlDocument.appendChild(root);

      const make = (name, klass) => {
        const el = xmlDocument.createElement(name);
        if (klass !== null) el.setAttribute("class", klass);
        root.appendChild(el);
        return el;
      };

      const a = make("a", "box");
      make("plain", null);
      const b = make("b", "box highlight");

      const boxes = Array.from(xmlDocument.getElementsByClassName("box"), n => n.localName);
      const both = Array.from(xmlDocument.getElementsByClassName("box highlight"), n => n.localName);
      const empty = xmlDocument.getElementsByClassName("").length;
      const scoped = Array.from(a.getElementsByClassName("box"), n => n.localName);

      return { boxes, both, empty, scoped };
    });
    """

    test "getElementsByClassName matches the browser", %{js: expected} do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      Node.append_child(document, root)

      make = fn name, klass ->
        el = DOM.create_element(document, name)
        if klass, do: Element.set_attribute(el, "class", klass)
        Node.append_child(root, el)
        el
      end

      a = make.("a", "box")
      make.("plain", nil)
      make.("b", "box highlight")

      result = %{
        "boxes" =>
          document |> DOM.get_elements_by_class_name("box") |> Enum.map(&Element.local_name/1),
        "both" =>
          document
          |> DOM.get_elements_by_class_name("box highlight")
          |> Enum.map(&Element.local_name/1),
        "empty" => document |> DOM.get_elements_by_class_name("") |> length(),
        "scoped" => a |> DOM.get_elements_by_class_name("box") |> Enum.map(&Element.local_name/1)
      }

      assert result == expected
    end
  end
end
