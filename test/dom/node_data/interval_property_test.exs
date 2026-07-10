defmodule DOM.NodeData.IntervalPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DOM.NodeData.Table

  # The primary correctness proof for `Table.interval/2` and, later, the whole
  # nested-set adjacency subsystem. We generate a random sequence of tree
  # operations (append / prepend / insert-after) and apply each by allocating the
  # new node's extent with `Table.interval(a, b)` against the correct sibling
  # bounds. After every op we assert the nested-set invariant that
  # `check_consistency!`'s forward walk will encode:
  #
  #   * containment — every child's extent lies strictly inside its parent's
  #     (`parent.start < child.start < child.stop < parent.stop`);
  #   * sibling order + disjointness — a parent's children, in insertion order,
  #     have strictly increasing, non-overlapping [start, stop] intervals.
  #
  # The `a, b` pairs handed to `interval` are exactly those a real op sequence
  # produces (including deep insert-between chains), so `interval`'s corners are
  # covered by construction. With the current dummy `interval` (always the root
  # extent), the second inserted node collides — so this property is RED until the
  # real arithmetic-quartile allocator lands.

  # The model tree: root (id 0) with the fixed root extent, plus a map of
  #   id => %{parent: id, start: binary, stop: binary, children: [id]}
  defp new_tree do
    %{
      next_id: 1,
      nodes: %{0 => %{parent: nil, start: <<0x00>>, stop: <<0x80>>, children: []}}
    }
  end

  # Ops reference an existing parent by index into the current id list.
  # :append   — allocate between the parent's last child stop and the parent stop
  # :prepend  — allocate between the parent start and the parent's first child stop
  # :after    — allocate after a chosen existing child of the parent
  defp op_gen do
    gen all(
          kind <- member_of([:append, :prepend, :after]),
          parent_pick <- float(min: 0.0, max: 1.0),
          child_pick <- float(min: 0.0, max: 1.0)
        ) do
      {kind, parent_pick, child_pick}
    end
  end

  defp apply_op({kind, parent_pick, child_pick}, tree) do
    ids = Map.keys(tree.nodes)
    parent_id = Enum.at(ids, trunc(parent_pick * (length(ids) - 1)))
    parent = tree.nodes[parent_id]

    {a, b, insert_at} = bounds(kind, parent, tree, child_pick)
    {start, stop} = Table.interval(a, b)

    id = tree.next_id
    child = %{parent: parent_id, start: start, stop: stop, children: []}
    new_children = List.insert_at(parent.children, insert_at, id)

    nodes =
      tree.nodes
      |> Map.put(id, child)
      |> Map.put(parent_id, %{parent | children: new_children})

    %{tree | next_id: id + 1, nodes: nodes}
  end

  # Compute the (a, b) bounds fed to interval and the position in the child list.
  defp bounds(:append, parent, tree, _child_pick) do
    a = if last = List.last(parent.children), do: tree.nodes[last].stop, else: parent.start
    {a, parent.stop, length(parent.children)}
  end

  defp bounds(:prepend, parent, tree, _child_pick) do
    # Prepend inserts before the first child, so the new extent must sit entirely
    # below it — ceiling is the first child's START (not its stop, which would
    # overlap the first child's own interval).
    b = if first = List.first(parent.children), do: tree.nodes[first].start, else: parent.stop
    {parent.start, b, 0}
  end

  defp bounds(:after, parent, tree, child_pick) do
    case parent.children do
      [] ->
        {parent.start, parent.stop, 0}

      children ->
        i = trunc(child_pick * (length(children) - 1))
        from = tree.nodes[Enum.at(children, i)]
        next = Enum.at(children, i + 1)
        b = if next, do: tree.nodes[next].start, else: parent.stop
        {from.stop, b, i + 1}
    end
  end

  # Assert the nested-set invariants over the whole model tree.
  defp assert_nested_set!(tree) do
    Enum.each(tree.nodes, fn {id, node} ->
      # containment: child strictly inside parent
      if node.parent do
        p = tree.nodes[node.parent]

        assert p.start < node.start and node.start < node.stop and node.stop < p.stop,
               "containment violated for #{id}: parent #{inspect({p.start, p.stop})} " <>
                 "child #{inspect({node.start, node.stop})}"
      end

      # a node's own start < stop
      assert node.start < node.stop, "empty/inverted extent for #{id}: #{inspect(node)}"

      # sibling order + disjointness
      intervals = Enum.map(node.children, &{tree.nodes[&1].start, tree.nodes[&1].stop})

      intervals
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{_s1, stop1}, {start2, _s2}] ->
        assert stop1 < start2,
               "siblings overlap/misordered under #{id}: #{inspect({stop1, start2})}"
      end)
    end)
  end

  property "interval allocations keep the tree a valid nested set" do
    check all(ops <- list_of(op_gen(), min_length: 1, max_length: 40)) do
      final =
        Enum.reduce(ops, new_tree(), fn op, tree ->
          tree = apply_op(op, tree)
          assert_nested_set!(tree)
          tree
        end)

      assert_nested_set!(final)
    end
  end

  # --- Pure interval/2 contract ---------------------------------------------

  # Bytes biased toward the boundaries the algorithm cares about — 0x00/0x01
  # (low edge), 0x7F/0x80 (the root split), 0xFE/0xFF (the top edge, where keys
  # must length-extend rather than carry) — so tight-gap (delta 1/2) and
  # 0xFF-boundary pairs are generated constantly rather than by luck. A plain
  # `binary()` almost never produces adjacent-byte or shared-long-prefix pairs,
  # which is exactly where interval's hard cases live.
  defp corner_byte do
    frequency([
      {4, member_of([0x00, 0x01, 0x02, 0x03, 0x7F, 0x80, 0xFE, 0xFF])},
      {1, integer(0..255)}
    ])
  end

  # Short binaries built from corner bytes: short so shared prefixes and adjacent
  # values collide often (the tight-gap / descent path); min one byte (contract).
  defp corner_binary do
    gen all(bytes <- list_of(corner_byte(), min_length: 1, max_length: 4)) do
      :erlang.list_to_binary(bytes)
    end
  end

  # A strictly-increasing pair {a, b} (a < b in Erlang term order), rich in shared
  # prefixes, adjacent-byte, and 0xFF-boundary cases. Rejects pairs where `a` is a
  # proper prefix of `b`: that is OUT OF CONTRACT for interval/graft (real bounds
  # are disjoint sibling gap keys, never in a prefix relationship — see
  # Table.interval/2's doc).
  defp ordered_pair do
    gen all(x <- corner_binary(), y <- corner_binary(), x != y, not prefix_pair?(x, y)) do
      if x < y, do: {x, y}, else: {y, x}
    end
  end

  # True if the smaller of the two is a proper prefix of the larger.
  defp prefix_pair?(x, y) do
    {lo, hi} = if x < y, do: {x, y}, else: {y, x}
    byte_size(lo) < byte_size(hi) and binary_part(hi, 0, byte_size(lo)) == lo
  end

  property "interval(a, b) returns {c, d} strictly between: a < c < d < b" do
    check all({a, b} <- ordered_pair()) do
      {c, d} = Table.interval(a, b)

      assert a < c, "start not above lower bound: a=#{inspect(a)} c=#{inspect(c)}"
      assert c < d, "start not below stop: c=#{inspect(c)} d=#{inspect(d)}"
      assert d < b, "stop not below upper bound: d=#{inspect(d)} b=#{inspect(b)}"
    end
  end

  # --- multispan/3 contract --------------------------------------------------

  property "multispan(a, b, n) returns n ordered, disjoint windows strictly inside (a, b)" do
    check all({a, b} <- ordered_pair(), count <- integer(1..8)) do
      windows = Table.multispan(a, b, count)

      assert length(windows) == count,
             "wrong window count for #{inspect({a, b})} n=#{count}: got #{length(windows)}"

      # every window is a valid non-empty extent strictly inside the gap
      Enum.each(windows, fn {s, e} ->
        assert is_binary(s) and byte_size(s) > 0 and is_binary(e) and byte_size(e) > 0
        assert s < e, "empty/inverted window #{inspect({s, e})}"
        assert a < s and e < b, "window #{inspect({s, e})} escapes gap #{inspect({a, b})}"
      end)

      # windows are ordered and mutually disjoint with a gap between them:
      # e_i < s_{i+1} for consecutive windows.
      windows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{_s1, e1}, {s2, _e2}] ->
        assert e1 < s2, "windows overlap/misordered: #{inspect({e1, s2})}"
      end)
    end
  end

  # --- graft/5 contract ------------------------------------------------------

  # Build a subtree of real interval-carved extents inside `(pstart, pstop)`,
  # recursing to `depth`. Returns a flat list of `%{start, stop}` nodes (the root
  # first) — every node's keys share the root window's prefix, as in a real tree.
  defp carve_subtree(pstart, pstop, depth, breadth) do
    root = %{start: pstart, stop: pstop}

    children =
      if depth <= 0 do
        []
      else
        {kids, _} =
          Enum.map_reduce(1..breadth, pstart, fn _i, prev ->
            {cstart, cstop} = Table.interval(prev, pstop)
            {carve_subtree(cstart, cstop, depth - 1, breadth), cstop}
          end)

        List.flatten(kids)
      end

    [root | children]
  end

  defp subtree_gen do
    gen all(depth <- integer(0..3), breadth <- integer(1..3)) do
      # carve inside a nested window so the shared prefix is non-trivial
      {rs, re} = Table.interval(<<0x10>>, <<0x70>>)
      carve_subtree(rs, re, depth, breadth)
    end
  end

  property "graft relocates a subtree into a gap, preserving order and containment" do
    check all(nodes <- subtree_gen(), {gap_a, gap_b} <- ordered_pair()) do
      [root | _] = nodes
      grafted = Table.graft(nodes, root.start, root.stop, gap_a, gap_b)
      [new_root | _] = grafted

      # every remapped key is a valid, non-empty binary
      Enum.each(grafted, fn n ->
        assert is_binary(n.start) and byte_size(n.start) > 0
        assert is_binary(n.stop) and byte_size(n.stop) > 0
        assert n.start < n.stop, "inverted extent after graft: #{inspect(n)}"
      end)

      # the whole subtree lands strictly inside the destination gap
      Enum.each(grafted, fn n ->
        assert gap_a < n.start and n.stop < gap_b,
               "grafted node #{inspect({n.start, n.stop})} escapes gap " <>
                 "#{inspect({gap_a, gap_b})}"
      end)

      # relative order is preserved: pairing old→new, the sort by start matches
      old_order = nodes |> Enum.sort_by(& &1.start) |> Enum.map(& &1.start)
      new_by_old = Enum.zip(nodes, grafted)

      new_order =
        new_by_old |> Enum.sort_by(fn {o, _} -> o.start end) |> Enum.map(fn {_, n} -> n.start end)

      assert new_order == Enum.sort(new_order), "graft did not preserve start ordering"
      assert length(old_order) == length(new_order)

      # containment preserved: any node contained in another before is after too
      for {o1, n1} <- new_by_old, {o2, n2} <- new_by_old, o1 != o2 do
        if o1.start < o2.start and o2.stop < o1.stop do
          assert n1.start < n2.start and n2.stop < n1.stop,
                 "graft broke containment for #{inspect({o1, o2})} -> #{inspect({n1, n2})}"
        end
      end

      _ = new_root
    end
  end
end
