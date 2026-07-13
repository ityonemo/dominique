defmodule DOM.NodeData.RehomeTest do
  use ExUnit.Case, async: true

  # Isolation tests for DOM.NodeData.rehome/4 — the cross-table subtree relocator.
  # Build a small tree on bare tids, apply a rehome transform, and assert the
  # consistency net (span rows mirror records, roots match topology) still holds.

  alias DOM.NodeData
  alias DOM.NodeData.Table

  setup do
    {:ok,
     nodes: :ets.new(:test_nodes, [:set, :private]),
     index: :ets.new(:test_index, [:ordered_set, :private])}
  end

  # doc -> ul -> [a, b -> [c]], target. Span rows mirrored. Returns the ids.
  defp tree(nodes, index) do
    doc = Table.create_document(nodes, index)
    ul = Table.create_element(nodes, index, "ul")
    a = Table.create_element(nodes, index, "a")
    b = Table.create_element(nodes, index, "b")
    c = Table.create_element(nodes, index, "c")
    target = Table.create_element(nodes, index, "target")
    Table.append_child(nodes, doc, ul)
    Table.append_child(nodes, ul, a)
    Table.append_child(nodes, ul, b)
    Table.append_child(nodes, b, c)
    Table.append_child(nodes, doc, target)
    Table.rehome_subtree(nodes, index, doc)
    %{doc: doc, ul: ul, a: a, b: b, c: c, target: target}
  end

  # The window (root, start, stop) of a node's subtree, from its record.
  defp window(nodes, id) do
    rec = Table.fetch!(nodes, id)
    root = Map.get(rec, :root) || id
    {root, rec.start, rec.stop}
  end

  test "baseline tree is consistent", %{nodes: nodes, index: index} do
    tree(nodes, index)
    assert Table.check_consistency!(nodes, index) == :ok
  end

  test "rehome-to-self detaches a subtree (b's subtree becomes its own tree)",
       %{nodes: nodes, index: index} do
    ids = tree(nodes, index)

    # Detach b's subtree: keep start/stop byte-keys, rewrite root -> b (self), and b's
    # own rows lose their parent. Descendants (c) get root -> b, keep their parent.
    {_old_root, start, stop} = window(nodes, ids.b)

    NodeData.rehome(nodes, index, {ids.doc, start, stop}, fn
      {{:span, _r, key, kind, _parent}, {node_id, type}} when node_id == ids.b ->
        {{:span, ids.b, key, kind, nil}, {node_id, type}}

      {{:span, _r, key, kind, parent}, val} ->
        {{:span, ids.b, key, kind, parent}, val}
    end)

    assert Table.check_consistency!(nodes, index) == :ok
    # b is now a detached tree root (root == self); c is still its child.
    assert Table.parent(nodes, ids.b) == nil
    assert Table.fetch!(nodes, ids.b).root == ids.b
    assert Table.children_by_extent(nodes, ids.b) == [ids.c]
    assert Table.fetch!(nodes, ids.c).root == ids.b
    # ul lost b (only a remains under ul).
    assert Table.children_by_extent(nodes, ids.ul) == [ids.a]
  end

  test "rehome into a new parent slot (move b's subtree under target)",
       %{nodes: nodes, index: index} do
    ids = tree(nodes, index)

    # Move b's subtree under `target`: graft computes each moved node's NEW start/stop in
    # target's append gap; root -> target's tree root (doc); b's parent -> target.
    target = Table.fetch!(nodes, ids.target)
    b = Table.fetch!(nodes, ids.b)
    {gap_a, gap_b} = {target.start, target.stop}

    # graft returns records with remapped start/stop (root first). Build id -> new extent.
    moved_ids = [ids.b | Table.descendant_ids(nodes, ids.b)]
    recs = Enum.map(moved_ids, &Table.fetch!(nodes, &1))
    grafted = Table.graft(recs, b.start, b.stop, gap_a, gap_b)
    new_extent = Map.new(Enum.zip(moved_ids, grafted), fn {id, r} -> {id, {r.start, r.stop}} end)

    new_root = Map.get(target, :root) || ids.target
    {_old_root, start, stop} = window(nodes, ids.b)

    NodeData.rehome(nodes, index, {ids.doc, start, stop}, fn
      {{:span, _r, _key, kind, _parent}, {node_id, type}} when node_id == ids.b ->
        {ns, ne} = Map.fetch!(new_extent, ids.b)
        key = if kind == :start, do: ns, else: ne
        {{:span, new_root, key, kind, ids.target}, {node_id, type}}

      {{:span, _r, _key, kind, parent}, {node_id, type}} ->
        {ns, ne} = Map.fetch!(new_extent, node_id)
        key = if kind == :start, do: ns, else: ne
        {{:span, new_root, key, kind, parent}, {node_id, type}}
    end)

    assert Table.check_consistency!(nodes, index) == :ok
    # b now under target; ul keeps only a.
    assert Table.children_by_extent(nodes, ids.target) == [ids.b]
    assert Table.children_by_extent(nodes, ids.b) == [ids.c]
    assert Table.parent(nodes, ids.b) == ids.target
    assert Table.fetch!(nodes, ids.b).root == ids.doc
    assert Table.fetch!(nodes, ids.c).root == ids.doc
    assert Table.children_by_extent(nodes, ids.ul) == [ids.a]
  end
end
