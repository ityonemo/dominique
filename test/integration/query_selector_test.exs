defmodule Integration.QuerySelectorTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  # A battery of selectors run against one shared tree, diffed against real
  # browser querySelectorAll. Every element carries an explicit id so results are
  # comparable across the Elixir/JS boundary by id, in document order. The JS and
  # Elixir sides each list the selectors independently; the test asserts the two
  # result maps are equal.
  @selectors [
    "a",
    "*",
    ".box",
    "#target",
    "[data-role]",
    "[data-role=nav]",
    "[class~=highlight]",
    "a.box",
    "ul > li",
    "section li",
    "h1 + p",
    "h1 ~ p",
    "li:first-child",
    "li:last-child",
    "li:nth-child(2n)",
    "li:nth-child(odd)",
    ":root",
    "li:not(.box)",
    "li:is(.box, :last-child)",
    "div:has(> p)",
    "section a, ul li"
  ]

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/dom/nodes"
    @js """
    return await page.evaluate(() => {
      const doc = document.implementation.createDocument(null, null);
      const el = (name, id, attrs, children) => {
        const e = doc.createElement(name);
        e.setAttribute("id", id);
        for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, v);
        for (const c of children || []) e.appendChild(c);
        return e;
      };

      doc.appendChild(
        el("section", "section", {}, [
          el("h1", "h1", {}),
          el("ul", "ul", {}, [
            el("li", "li1", { class: "box" }, [ el("a", "innerA", { "data-role": "nav" }) ]),
            el("li", "li2", { class: "highlight" }),
            el("li", "li3", { class: "box highlight" })
          ]),
          el("p", "p1", {}),
          el("p", "p2", {}),
          el("div", "withP", {}, [ el("p", "nestedP", {}) ]),
          el("a", "target", { class: "box" })
        ])
      );

      const selectors = [
        "a", "*", ".box", "#target", "[data-role]", "[data-role=nav]",
        "[class~=highlight]", "a.box", "ul > li", "section li", "h1 + p",
        "h1 ~ p", "li:first-child", "li:last-child", "li:nth-child(2n)",
        "li:nth-child(odd)", ":root", "li:not(.box)",
        "li:is(.box, :last-child)", "div:has(> p)", "section a, ul li"
      ];

      const results = {};
      for (const sel of selectors) {
        results[sel] = Array.from(doc.querySelectorAll(sel), n => n.getAttribute("id"));
      }
      return results;
    });
    """

    test "querySelectorAll matches the browser across a battery of selectors", %{js: expected} do
      document = DOM.new()
      Node.append_child(document, build(document))

      results =
        Map.new(@selectors, fn selector ->
          ids =
            document
            |> DOM.query_selector_all(selector)
            |> Enum.map(&Element.get_attribute(&1, "id"))

          {selector, ids}
        end)

      assert results == expected
    end

    @js """
    return await page.evaluate(() => {
      const doc = document.implementation.createDocument(null, null);
      const root = doc.createElement("root");
      const a = doc.createElement("a");
      a.setAttribute("class", "box");
      root.appendChild(a);
      doc.appendChild(root);

      return {
        first: doc.querySelector("a") ? doc.querySelector("a").localName : null,
        missing: doc.querySelector("nope"),
        matchesClass: a.matches(".box"),
        matchesType: a.matches("b")
      };
    });
    """

    test "querySelector and matches agree with the browser", %{js: expected} do
      document = DOM.new()
      root = DOM.create_element(document, "root")
      a = DOM.create_element(document, "a")
      Element.set_attribute(a, "class", "box")
      Node.append_child(root, a)
      Node.append_child(document, root)

      result = %{
        "first" => document |> DOM.query_selector("a") |> local_name(),
        "missing" => DOM.query_selector(document, "nope"),
        "matchesClass" => DOM.matches(a, ".box"),
        "matchesType" => DOM.matches(a, "b")
      }

      assert result == expected
    end
  end

  # The same tree as the @js battery, with matching explicit ids.
  defp build(document) do
    el(document, "section", "section", [], [
      el(document, "h1", "h1"),
      el(document, "ul", "ul", [], [
        el(document, "li", "li1", [{"class", "box"}], [
          el(document, "a", "innerA", [{"data-role", "nav"}])
        ]),
        el(document, "li", "li2", [{"class", "highlight"}]),
        el(document, "li", "li3", [{"class", "box highlight"}])
      ]),
      el(document, "p", "p1"),
      el(document, "p", "p2"),
      el(document, "div", "withP", [], [el(document, "p", "nestedP")]),
      el(document, "a", "target", [{"class", "box"}])
    ])
  end

  defp el(document, name, id, attrs \\ [], children \\ []) do
    node = DOM.create_element(document, name)
    Element.set_attribute(node, "id", id)
    Enum.each(attrs, fn {k, v} -> Element.set_attribute(node, k, v) end)
    Enum.each(children, &Node.append_child(node, &1))
    node
  end

  defp local_name(nil), do: nil
  defp local_name(node), do: Element.local_name(node)
end
