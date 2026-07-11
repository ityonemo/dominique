defmodule Integration.NormalizeTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#dom-node-normalize"

    # normalize merges adjacent text runs and drops empty text nodes recursively;
    # compare the resulting child structure (nodeType + text data) against the
    # browser. Element children are reported by nodeType only (nodeName casing
    # differs and is not what normalize is about).
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString("<div id='p'></div>", "text/html");
      const p = doc.getElementById("p");
      const span = doc.createElement("span");
      span.append("deep", "", "ly");

      p.append("a", "", "b");
      p.append(span);
      p.append("c", "d");

      p.normalize();

      const dump = (node) => Array.from(node.childNodes, n =>
        n.nodeType === 3 ? ["text", n.data] : ["element", n.childNodes.length]);

      return { p: dump(p), span: dump(span) };
    });
    """

    test "normalize matches the browser", %{js: expected} do
      doc = DOM.new("<div id='p'></div>")
      p = DOM.query_selector(doc, "#p")
      span = DOM.create_element(doc, "span")
      Node.append(span, ["deep", "", "ly"])

      Node.append(p, ["a", "", "b"])
      Node.append(p, [span])
      Node.append(p, ["c", "d"])

      Node.normalize(p)

      dump = fn node ->
        node
        |> Node.child_nodes()
        |> Enum.map(fn
          %{type: :text} = n -> ["text", Node.value(n)]
          n -> ["element", length(Node.child_nodes(n))]
        end)
      end

      result = %{"p" => dump.(p), "span" => dump.(span)}
      assert result == expected
    end
  end
end
