defmodule Integration.RangeTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node
  alias DOM.Range

  @moduletag :integration

  # Range boundaries + comparison, diffed against the browser. Both sides build the
  # same tree from identical HTML and run the same sequence of boundary ops, then
  # report container ids + offsets + compare results.

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/dom/ranges"

    @html "<div id='a'><p id='p1'>hello</p><p id='p2'>world</p><span id='s'>x</span></div>"

    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='a'><p id='p1'>hello</p><p id='p2'>world</p><span id='s'>x</span></div>",
        "text/html");
      const a = doc.getElementById("a");
      const p1 = doc.getElementById("p1");
      const t1 = p1.firstChild; // "hello" text

      // r1: select_node(p1) -> (a, 0)..(a, 1)
      const r1 = doc.createRange();
      r1.selectNode(p1);

      // r2: a text range inside "hello", chars 1..4
      const r2 = doc.createRange();
      r2.setStart(t1, 1);
      r2.setEnd(t1, 4);

      // r3: selectNodeContents(a) -> (a,0)..(a,3)
      const r3 = doc.createRange();
      r3.selectNodeContents(a);

      const cid = (n) => n.id || n.nodeName;
      return {
        r1_start: [cid(r1.startContainer), r1.startOffset],
        r1_end:   [cid(r1.endContainer),   r1.endOffset],
        r1_collapsed: r1.collapsed,
        r2_start: [cid(r2.startContainer), r2.startOffset],
        r2_end:   [cid(r2.endContainer),   r2.endOffset],
        r3_end_offset: r3.endOffset,
        r3_common: cid(r3.commonAncestorContainer),
        // compareBoundaryPoints: START_TO_START=0
        cmp_r1_r3_ss: r1.compareBoundaryPoints(Range.START_TO_START, r3),
        cmp_r2_r1_ss: r2.compareBoundaryPoints(Range.START_TO_START, r1)
      };
    });
    """

    test "range boundaries and comparison match the browser", %{js: expected} do
      doc = DOM.new(@html)
      a = DOM.query_selector(doc, "#a")
      p1 = DOM.query_selector(doc, "#p1")
      [t1] = Node.child_nodes(p1)

      r1 = Range.select_node(Range.create_range(doc), p1)
      r2 = Range.create_range(doc) |> Range.set_start(t1, 1) |> Range.set_end(t1, 4)
      r3 = Range.select_node_contents(Range.create_range(doc), a)

      cid = fn
        %Node{type: :element} = node ->
          DOM.Element.get_attribute(node, "id") || Node.node_name(node)

        node ->
          Node.node_name(node)
      end

      result = %{
        "r1_start" => [cid.(Range.start_container(r1)), Range.start_offset(r1)],
        "r1_end" => [cid.(Range.end_container(r1)), Range.end_offset(r1)],
        "r1_collapsed" => Range.collapsed?(r1),
        "r2_start" => [cid.(Range.start_container(r2)), Range.start_offset(r2)],
        "r2_end" => [cid.(Range.end_container(r2)), Range.end_offset(r2)],
        "r3_end_offset" => Range.end_offset(r3),
        "r3_common" => cid.(Range.common_ancestor_container(r3)),
        "cmp_r1_r3_ss" => Range.compare_boundary_points(r1, :start_to_start, r3),
        "cmp_r2_r1_ss" => Range.compare_boundary_points(r2, :start_to_start, r1)
      }

      assert result == expected
    end
  end

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/dom/ranges"

    # Live-range mutation: boundaries adjust as the tree changes under a held range.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<ul id='u'><li id='a'>a</li><li id='b'>b</li><li id='c'>c</li></ul>",
        "text/html");
      const u = doc.getElementById("u");
      const a = doc.getElementById("a");
      const b = doc.getElementById("b");

      // r: (u, 2)
      const r = doc.createRange();
      r.setStart(u, 2);
      r.setEnd(u, 2);

      // insert a new li before b (index 1) -> offset 2 -> 3
      const nl = doc.createElement("li");
      u.insertBefore(nl, b);
      const after_insert = r.startOffset;

      // remove a (index 0) -> offset 3 -> 2
      a.remove();
      const after_remove = r.startOffset;

      return { after_insert, after_remove };
    });
    """

    test "boundaries adjust under insert/remove like the browser", %{js: expected} do
      doc = DOM.new("<ul id='u'><li id='a'>a</li><li id='b'>b</li><li id='c'>c</li></ul>")
      u = DOM.query_selector(doc, "#u")
      a = DOM.query_selector(doc, "#a")
      b = DOM.query_selector(doc, "#b")

      r = Range.create_range(doc) |> Range.set_start(u, 2) |> Range.set_end(u, 2)

      Node.insert_before(u, DOM.create_element(doc, "li"), b)
      after_insert = Range.start_offset(r)

      Node.remove_child(u, a)
      after_remove = Range.start_offset(r)

      assert %{"after_insert" => after_insert, "after_remove" => after_remove} == expected
    end
  end

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/dom/ranges"

    # cloneContents: the fragment's serialized innerHTML matches the browser across
    # same-text, whole-child, and partial-both-ends ranges.
    @js """
    return await page.evaluate(() => {
      const html =
        "<div id='d'><p id='p1'>hello</p><p id='p2'>world</p><p id='p3'>!</p></div>";
      const frag = (setup) => {
        const doc = new DOMParser().parseFromString(html, "text/html");
        const wrap = doc.createElement("div");
        wrap.appendChild(setup(doc).cloneContents());
        return wrap.innerHTML;
      };

      return {
        same_text: frag((doc) => {
          const t = doc.getElementById("p1").firstChild;
          const r = doc.createRange(); r.setStart(t, 1); r.setEnd(t, 4); return r;
        }),
        whole_children: frag((doc) => {
          const d = doc.getElementById("d");
          const r = doc.createRange(); r.setStart(d, 1); r.setEnd(d, 3); return r;
        }),
        partial_both: frag((doc) => {
          const t1 = doc.getElementById("p1").firstChild;
          const t2 = doc.getElementById("p2").firstChild;
          const r = doc.createRange(); r.setStart(t1, 2); r.setEnd(t2, 3); return r;
        })
      };
    });
    """

    test "cloneContents matches the browser", %{js: expected} do
      html = "<div id='d'><p id='p1'>hello</p><p id='p2'>world</p><p id='p3'>!</p></div>"

      frag = fn setup ->
        doc = DOM.new(html)
        wrap = DOM.create_element(doc, "div")
        Node.append_child(wrap, Range.clone_contents(setup.(doc)))
        DOM.Element.inner_html(wrap)
      end

      result = %{
        "same_text" =>
          frag.(fn doc ->
            [t] = Node.child_nodes(DOM.query_selector(doc, "#p1"))
            Range.create_range(doc) |> Range.set_start(t, 1) |> Range.set_end(t, 4)
          end),
        "whole_children" =>
          frag.(fn doc ->
            d = DOM.query_selector(doc, "#d")
            Range.create_range(doc) |> Range.set_start(d, 1) |> Range.set_end(d, 3)
          end),
        "partial_both" =>
          frag.(fn doc ->
            [t1] = Node.child_nodes(DOM.query_selector(doc, "#p1"))
            [t2] = Node.child_nodes(DOM.query_selector(doc, "#p2"))
            Range.create_range(doc) |> Range.set_start(t1, 2) |> Range.set_end(t2, 3)
          end)
      }

      assert result == expected
    end
  end
end
