defmodule Integration.NodeComparisonTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#dom-node-comparedocumentposition"

    # compareDocumentPosition for CONNECTED nodes (deterministic — the disconnected
    # case is implementation-specific and browsers disagree, so it is unit-tested
    # only), plus contains / isEqualNode.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='a'><span id='b'></span><span id='c'></span></div>", "text/html");
      const a = doc.getElementById("a"), b = doc.getElementById("b"), c = doc.getElementById("c");

      const eqDoc = new DOMParser().parseFromString(
        "<div><p class='k'>hi</p><p class='k'>hi</p><p class='j'>hi</p></div>", "text/html");
      const [p1, p2, p3] = eqDoc.querySelectorAll("p");

      return {
        a_vs_b: a.compareDocumentPosition(b),
        b_vs_a: b.compareDocumentPosition(a),
        b_vs_c: b.compareDocumentPosition(c),
        c_vs_b: c.compareDocumentPosition(b),
        self: a.compareDocumentPosition(a),
        contains_ab: a.contains(b),
        contains_ba: b.contains(a),
        equal_p1p2: p1.isEqualNode(p2),
        equal_p1p3: p1.isEqualNode(p3)
      };
    });
    """

    test "compareDocumentPosition / contains / isEqualNode match the browser", %{js: expected} do
      doc = DOM.new("<div id='a'><span id='b'></span><span id='c'></span></div>")
      a = DOM.query_selector(doc, "#a")
      b = DOM.query_selector(doc, "#b")
      c = DOM.query_selector(doc, "#c")

      eq_doc = DOM.new("<div><p class='k'>hi</p><p class='k'>hi</p><p class='j'>hi</p></div>")
      [p1, p2, p3] = DOM.query_selector_all(eq_doc, "p")

      result = %{
        "a_vs_b" => Node.compare_document_position(a, b),
        "b_vs_a" => Node.compare_document_position(b, a),
        "b_vs_c" => Node.compare_document_position(b, c),
        "c_vs_b" => Node.compare_document_position(c, b),
        "self" => Node.compare_document_position(a, a),
        "contains_ab" => Node.contains(a, b),
        "contains_ba" => Node.contains(b, a),
        "equal_p1p2" => Node.is_equal_node(p1, p2),
        "equal_p1p3" => Node.is_equal_node(p1, p3)
      }

      assert result == expected
    end
  end
end
