defmodule Integration.DocumentAccessorsTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#interface-document"

    # document accessors + adoptNode + importNode match the browser.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<form><input name='q'><input name='q'><input name='r'></form>", "text/html");

      const r = {
        doc_el: doc.documentElement.localName,
        body: doc.body.localName,
        head: doc.head.localName,
        name_q: doc.getElementsByName("q").length,
        name_r: doc.getElementsByName("r").length
      };

      // adoptNode
      const d1 = new DOMParser().parseFromString("<div id='s'><span id='x'>hi</span></div>", "text/html");
      const d2 = new DOMParser().parseFromString("<div id='d'></div>", "text/html");
      const adopted = d2.adoptNode(d1.getElementById("x"));
      r.adopt_removed = d1.getElementById("x") === null;
      r.adopt_html = adopted.outerHTML;

      // importNode
      const d3 = new DOMParser().parseFromString("<a id='imp'><b>deep</b></a>", "text/html");
      const src = d3.getElementById("imp");
      r.import_shallow = d2.importNode(src, false).outerHTML;
      r.import_deep = d2.importNode(src, true).outerHTML;
      r.import_src_intact = d3.getElementById("imp") !== null;
      return r;
    });
    """

    test "document accessors + adoptNode + importNode match the browser", %{js: expected} do
      doc = DOM.new("<form><input name='q'><input name='q'><input name='r'></form>")

      d1 = DOM.new("<div id='s'><span id='x'>hi</span></div>")
      d2 = DOM.new("<div id='d'></div>")
      adopted = DOM.adopt_node(d2, DOM.query_selector(d1, "#x"))

      d3 = DOM.new("<a id='imp'><b>deep</b></a>")
      src = DOM.query_selector(d3, "#imp")

      result = %{
        "doc_el" => Element.local_name(DOM.document_element(doc)),
        "body" => Element.local_name(DOM.body(doc)),
        "head" => Element.local_name(DOM.head(doc)),
        "name_q" => length(DOM.get_elements_by_name(doc, "q")),
        "name_r" => length(DOM.get_elements_by_name(doc, "r")),
        "adopt_removed" => DOM.query_selector(d1, "#x") == nil,
        "adopt_html" => Element.outer_html(adopted),
        "import_shallow" => Element.outer_html(DOM.import_node(d2, src, false)),
        "import_deep" => Element.outer_html(DOM.import_node(d2, src, true)),
        "import_src_intact" => DOM.query_selector(d3, "#imp") != nil
      }

      assert result == expected
    end
  end
end
