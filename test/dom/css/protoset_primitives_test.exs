defmodule DOM.CSS.ProtosetPrimitivesTest do
  use ExUnit.Case, async: true

  # Unit tests for the protoset engine primitives (DOM.CSS.Query). These run against a
  # bare nodes/index table built by CSSTable — no DOM GenServer — exercising the fused
  # index lookups and the extent-containment joins in isolation, before they are wired
  # into the combinator matcher.

  import CSSTable

  alias DOM.CSS.Query
  alias DOM.NodeData.IndexTable

  # A small tree:  root > [a.box > aa, b#target, c.box.hi]
  setup do
    {context, ids} =
      build(
        element(
          "root",
          [],
          [
            element("a", [{"class", "box"}], [element("aa", [], [], as: :aa)], as: :a),
            element("b", [{"id", "target"}], [], as: :b),
            element("c", [{"class", "box hi"}], [], as: :c)
          ],
          as: :root
        )
      )

    {:ok, context: context, ids: ids, root: ids.root, aa: ids.aa}
  end

  describe "seed / filter_protoset" do
    test "seed maps each id to itself" do
      assert Query.seed([:x, :y]) == %{x: :x, y: :y}
    end

    test "filter_protoset keeps entries whose key passes, preserving the value" do
      ps = %{a: :leaf1, b: :leaf2, c: :leaf3}
      assert Query.filter_protoset(ps, &(&1 != :b)) == %{a: :leaf1, c: :leaf3}
    end
  end

  describe "compound_lookup (fused membership + leaf_ref projection)" do
    test "intersects the class index with the protoset, keeping leaf_refs", %{
      context: %{index: index},
      ids: ids
    } do
      a = ids.a
      c = ids.c
      # protoset carries a distinct leaf_ref per key to prove projection.
      protoset = %{a => :leaf_a, c => :leaf_c, ids.b => :leaf_b}

      # .box matches a and c (not b); leaf_refs preserved from the protoset.
      assert Query.compound_lookup(index, protoset, :class, "box") == %{
               a => :leaf_a,
               c => :leaf_c
             }
    end

    test "id lookup fused", %{context: %{index: index}, ids: ids} do
      b = ids.b

      assert Query.compound_lookup(index, %{b => :leaf_b, ids.a => :leaf_a}, :id, "target") ==
               %{b => :leaf_b}
    end

    test "a key absent from the index yields nothing", %{context: %{index: index}, ids: ids} do
      # root has no class; asking for .box over just root is empty.
      assert Query.compound_lookup(index, %{ids.root => :r}, :class, "box") == %{}
    end
  end

  describe "resolve_extents" do
    test "returns {start, id, stop, parent, root, leaf_ref} in start (document) order", %{
      context: context,
      ids: ids,
      aa: aa
    } do
      protoset = %{ids.a => :la, ids.b => :lb, ids.c => :lc, aa => :laa}
      exts = Query.resolve_extents(context, protoset)

      # start-sorted == document order: a, aa, b, c
      order = Enum.map(exts, fn {_s, id, _stop, _p, _r, _l} -> id end)
      assert order == [ids.a, aa, ids.b, ids.c]

      # each tuple carries the protoset's leaf_ref and a well-formed window
      for {start, id, stop, _parent, _root, leaf} <- exts do
        assert start < stop
        assert leaf == Map.fetch!(protoset, id)
      end
    end

    test "elements_only? still returns all (every node here is an element)", %{
      context: context,
      ids: ids
    } do
      ps = %{ids.a => :la, ids.b => :lb}
      assert length(Query.resolve_extents(context, ps, true)) == 2
    end
  end

  describe "resolve_descendants (containment sweep)" do
    test ":subject projection keys by subject, value = leaf_ref", %{
      context: context,
      ids: ids,
      aa: aa
    } do
      left = Query.resolve_extents(context, %{ids.a => :la})
      subject = Query.resolve_extents(context, %{aa => :leaf_aa})

      # aa is contained by a -> matches, keyed by aa, valued by its leaf_ref.
      assert Query.resolve_descendants(left, subject, :subject) == %{aa => :leaf_aa}
    end

    test ":current projection keys by the containing left id", %{
      context: context,
      ids: ids,
      aa: aa
    } do
      left = Query.resolve_extents(context, %{ids.a => :la})
      subject = Query.resolve_extents(context, %{aa => :leaf_aa})

      assert Query.resolve_descendants(left, subject, :current) == %{ids.a => :leaf_aa}
    end

    test "a non-descendant (sibling) does NOT match", %{context: context, ids: ids} do
      left = Query.resolve_extents(context, %{ids.a => :la})
      subject = Query.resolve_extents(context, %{ids.b => :leaf_b})
      # b is a sibling of a, not contained by it.
      assert Query.resolve_descendants(left, subject, :subject) == %{}
    end

    test "different-root nodes never match (containment is per-tree)", %{
      context: context,
      ids: ids,
      aa: aa
    } do
      # Build a fake left ext with a bogus root so nesting is impossible.
      [{s, id, stop, p, _root, l}] = Query.resolve_extents(context, %{ids.a => :la})
      left_other_root = [{s, id, stop, p, make_ref(), l}]
      subject = Query.resolve_extents(context, %{aa => :leaf_aa})
      assert Query.resolve_descendants(left_other_root, subject, :subject) == %{}
    end
  end

  describe "resolve_child (parent hash-join)" do
    test "aa's parent is a -> matches", %{context: context, ids: ids, aa: aa} do
      left = Query.resolve_extents(context, %{ids.a => :la})
      subject = Query.resolve_extents(context, %{aa => :leaf_aa})
      assert Query.resolve_child(left, subject, :subject) == %{aa => :leaf_aa}
    end

    test "a deeper descendant is NOT a child", %{context: context, ids: ids, aa: aa} do
      # root is aa's grandparent, not parent.
      left = Query.resolve_extents(context, %{ids.root => :lr})
      subject = Query.resolve_extents(context, %{aa => :leaf_aa})
      assert Query.resolve_child(left, subject, :subject) == %{}
    end
  end

  describe "IndexTable.span_starts backing" do
    test "emits start-sorted tuples for a protoset", %{context: %{index: index}, ids: ids, aa: aa} do
      ps = %{ids.a => :la, aa => :laa, ids.b => :lb}
      rows = IndexTable.span_starts(index, ps)
      starts = Enum.map(rows, fn {s, _root, _parent, _id, _leaf} -> s end)
      assert starts == Enum.sort(starts)
    end
  end
end
