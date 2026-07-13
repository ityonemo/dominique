defmodule Integration.TraversalTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node
  alias DOM.NodeIterator
  alias DOM.TreeWalker

  @moduletag :integration

  @html "<div id='root'><div id='a'><span id='b'>t1</span><span id='c'>t2</span></div>" <>
          "<p id='d'>t3</p><!--cmt--></div>"

  playwright do
    @link "https://dom.spec.whatwg.org/#traversal"

    # TreeWalker + NodeIterator traversal sequences (elements, text, SHOW_ALL, and a
    # reject filter) compared against the browser.
    @js """
    return await page.evaluate(() => {
      const host = document.createElement("div");
      host.innerHTML = "#{@html}";
      document.body.appendChild(host);
      const root = host.querySelector("#root");
      const NF = NodeFilter;
      const tag = (n) => n.id || n.data || n.nodeName;

      const twSeq = (show, filt) => {
        const w = document.createTreeWalker(root, show, filt || null);
        const s = []; let n; while (n = w.nextNode()) s.push(tag(n)); return s;
      };
      const niSeq = (show) => {
        const it = document.createNodeIterator(root, show);
        const s = []; let n; while (n = it.nextNode()) s.push(tag(n)); return s;
      };

      const out = {
        tw_elements: twSeq(NF.SHOW_ELEMENT),
        tw_text: twSeq(NF.SHOW_TEXT),
        tw_all: (() => { const w = document.createTreeWalker(root, NF.SHOW_ALL); const s=[]; let n; while(n=w.nextNode()) s.push(n.nodeType); return s; })(),
        tw_reject: twSeq(NF.SHOW_ELEMENT, { acceptNode: (n) => n.id === "a" ? NF.FILTER_REJECT : NF.FILTER_ACCEPT }),
        tw_skip: twSeq(NF.SHOW_ELEMENT, { acceptNode: (n) => n.id === "a" ? NF.FILTER_SKIP : NF.FILTER_ACCEPT }),
        ni_elements: niSeq(NF.SHOW_ELEMENT),
        ni_all: (() => { const it = document.createNodeIterator(root, NF.SHOW_ALL); const s=[]; let n; while(n=it.nextNode()) s.push(n.nodeType); return s; })(),
      };
      document.body.removeChild(host);
      return out;
    });
    """

    test "traversal sequences match the browser", %{js: expected} do
      doc = DOM.new("<body>#{@html}</body>")
      root = DOM.query_selector(doc, "#root")

      tag = fn
        %Node{type: :element} = n -> DOM.Element.get_attribute(n, "id") || Node.node_name(n)
        %Node{type: :comment} = n -> Node.value(n)
        n -> Node.value(n)
      end

      tw_seq = fn show, filt ->
        w = DOM.create_tree_walker(root, show, filt)
        drain_tw(w, tag)
      end

      ni_seq = fn show ->
        it = DOM.create_node_iterator(root, show)
        drain_ni(it, tag)
      end

      reject_a = fn n ->
        if DOM.Element.get_attribute(n, "id") == "a", do: :reject, else: :accept
      end

      skip_a = fn n -> if DOM.Element.get_attribute(n, "id") == "a", do: :skip, else: :accept end

      out = %{
        "tw_elements" => tw_seq.(:element, nil),
        "tw_text" => tw_seq.(:text, nil),
        "tw_all" => drain_tw(DOM.create_tree_walker(root, :all), &Node.node_type/1),
        "tw_reject" => tw_seq.(:element, reject_a),
        "tw_skip" => tw_seq.(:element, skip_a),
        "ni_elements" => ni_seq.(:element),
        "ni_all" => drain_ni(DOM.create_node_iterator(root, :all), &Node.node_type/1)
      }

      assert out == expected
    end

    defp drain_tw(w, tag) do
      case TreeWalker.next_node(w) do
        nil -> []
        node -> [tag.(node) | drain_tw(w, tag)]
      end
    end

    defp drain_ni(it, tag) do
      case NodeIterator.next_node(it) do
        nil -> []
        node -> [tag.(node) | drain_ni(it, tag)]
      end
    end
  end
end
