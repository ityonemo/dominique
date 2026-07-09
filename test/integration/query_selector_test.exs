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
    "section a, ul li",
    "p:first-of-type",
    "p:last-of-type",
    "p:nth-of-type(2)",
    "p:nth-last-of-type(1)",
    "div p:only-of-type",
    "h1:only-of-type"
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
        "li:is(.box, :last-child)", "div:has(> p)", "section a, ul li",
        "p:first-of-type", "p:last-of-type", "p:nth-of-type(2)",
        "p:nth-last-of-type(1)", "div p:only-of-type", "h1:only-of-type"
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

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/css/selectors"

    # Namespace prefixes in a querySelector context: no prefixes are declared, so
    # a real prefix (svg|rect) is a SyntaxError; bare and *| match any namespace
    # (including the SVG rect); the null-namespace prefix (|rect) matches nothing
    # because every parsed element is in the html/svg/mathml namespace.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='d'><svg><rect id='r'></rect></svg></div>", "text/html");
      const count = (sel) => {
        try { return doc.querySelectorAll(sel).length; }
        catch (e) { return "error"; }
      };
      return {
        bare: count("rect"),
        anyNs: count("*|rect"),
        nullNs: count("|rect"),
        badPrefix: count("svg|rect")
      };
    });
    """

    test "namespace prefixes match the browser", %{js: expected} do
      document = DOM.new("<div id='d'><svg><rect id='r'></rect></svg></div>")

      count = fn selector ->
        try do
          document |> DOM.query_selector_all(selector) |> length()
        rescue
          ArgumentError -> "error"
        end
      end

      result = %{
        "bare" => count.("rect"),
        "anyNs" => count.("*|rect"),
        "nullNs" => count.("|rect"),
        "badPrefix" => count.("svg|rect")
      }

      assert result == expected
    end
  end

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/css/selectors"

    # :lang and :dir inherit down the subtree from the element that declares the
    # lang/dir attribute; :lang uses the |= rule (en matches en-US). p2 overrides
    # lang to fr. Parsed from markup so both sides build the same tree.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='d' lang='en-US' dir='rtl'>" +
          "<p id='p1'>a</p><p id='p2' lang='fr'>b</p><span id='s'>c</span>" +
        "</div>", "text/html");
      const ids = (sel) =>
        Array.from(doc.querySelectorAll("#d, #d *")).filter(n => n.matches(sel))
          .map(n => n.getAttribute("id"));
      return {
        langEn: ids(":lang(en)"),
        langFr: ids(":lang(fr)"),
        dirRtl: ids(":dir(rtl)"),
        dirLtr: ids(":dir(ltr)")
      };
    });
    """

    test ":lang and :dir match the browser", %{js: expected} do
      document =
        DOM.new(
          "<div id='d' lang='en-US' dir='rtl'>" <>
            "<p id='p1'>a</p><p id='p2' lang='fr'>b</p><span id='s'>c</span>" <>
            "</div>"
        )

      ids = fn selector ->
        document
        |> DOM.query_selector_all(selector)
        |> Enum.map(&Element.get_attribute(&1, "id"))
      end

      result = %{
        "langEn" => ids.(":lang(en)"),
        "langFr" => ids.(":lang(fr)"),
        "dirRtl" => ids.(":dir(rtl)"),
        "dirLtr" => ids.(":dir(ltr)")
      }

      assert result == expected
    end
  end

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/css/selectors"

    # :scope is the element the query is rooted at. `el.querySelectorAll(":scope")`
    # returns el; `:scope > p` matches only el's direct-child p; a plain descendant
    # query never returns el itself.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='root'><p id='p1'>a</p><section><p id='p2'>b</p></section></div>",
        "text/html");
      const root = doc.getElementById("root");
      const ids = (sel) => Array.from(root.querySelectorAll(sel), n => n.getAttribute("id"));
      return {
        scope: ids(":scope"),
        scopeChild: ids(":scope > p"),
        plainP: ids("p"),
        rootMatchesScope: root.matches(":scope")
      };
    });
    """

    test ":scope matches the query root like the browser", %{js: expected} do
      document =
        DOM.new("<div id='root'><p id='p1'>a</p><section><p id='p2'>b</p></section></div>")

      root = DOM.query_selector(document, "#root")

      ids = fn selector ->
        root |> DOM.query_selector_all(selector) |> Enum.map(&Element.get_attribute(&1, "id"))
      end

      result = %{
        "scope" => ids.(":scope"),
        "scopeChild" => ids.(":scope > p"),
        "plainP" => ids.("p"),
        "rootMatchesScope" => DOM.matches(root, ":scope")
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
