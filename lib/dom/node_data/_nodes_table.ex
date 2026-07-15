defmodule DOM.NodeData.NodesTable do
  @moduledoc """
  In-process operations over a document's `nodes` ETS table (a `:set`) keyed by `node_id`
  (a `reference()`), holding the per-type `DOM.NodeData.*` records — no GenServer, no
  `%DOM.Node{}` handles. The derived index (span/membership/etc.) lives in
  `DOM.NodeData.IndexTable`; cross-table operations (create/relocate a node) live in
  `DOM.NodeData`.

  Records store `{node_id, data}`. Adjacency is nested-set: each node carries a `parent`
  pointer and a `{root, start, stop}` extent (binary order-keys via `DOM.NodeData.Extent`);
  a node's ordered children are the rows whose `parent` is it, read by `start` key
  (`children_by_extent/2`). "Moving" a node re-labels its subtree's extents (a fresh
  `Extent.interval` for a new node, an `Extent.graft` for an existing subtree).

  These functions assume SAME-DOCUMENT, hierarchy-valid operations. The server's `*_impl`
  wraps them with the cross-document / hierarchy checks the public DOM API additionally needs.
  """

  use MatchSpec

  alias DOM.NodeData
  alias DOM.NodeData.Extent

  require Extent
  @root_start Extent.root_start()
  @root_stop Extent.root_stop()

  @type tid :: :ets.tid()
  @type id :: reference()

  # ==========================================================================
  # Low-level record access
  # ==========================================================================

  @doc "The `DOM.NodeData.*` record for `id` (raises if absent)."
  @spec fetch!(tid, id) :: struct()
  def fetch!(tid, id) do
    [{^id, data}] = :ets.lookup(tid, id)
    data
  end

  @doc "Write the record for `id`."
  @spec put(tid, id, struct()) :: :ok
  def put(tid, id, data) do
    true = :ets.insert(tid, {id, data})
    :ok
  end

  @doc false
  # INTERNAL (for DOM.NodeData's create_child): carve a fresh single-child slot under
  # `parent_id` at `position`, returning `{dest_root, {start, stop}}` — the tree root the
  # child joins and its interval in the parent's gap. Nodes-table reads only; NodeData builds
  # the record and writes both tables.
  @spec carve_slot(tid, id, :last | {:before, id} | {:after, id}) ::
          {id, {Extent.t(), Extent.t()}}
  def carve_slot(nodes, parent_id, position) do
    parent = ensure_extent(nodes, parent_id)
    {gap_a, gap_b} = gap(nodes, parent_id, parent, position)
    {parent.root, Extent.interval(gap_a, gap_b)}
  end

  # The (gap_a, gap_b) window for a create/insert `position` under `parent_id`.
  defp gap(nodes, parent_id, parent, :last), do: extent_after_last(nodes, parent_id, parent)

  defp gap(nodes, parent_id, parent, {:before, ref}),
    do: extent_before(nodes, parent_id, parent, ref)

  defp gap(nodes, parent_id, parent, {:after, ref}),
    do: extent_after(nodes, parent_id, parent, ref)

  # ==========================================================================
  # Mutation (same-document, hierarchy-valid moves)
  # ==========================================================================

  @doc """
  Append `child_id` to `parent_id`, detaching it from any current parent first
  (a move). The subtree rooted at `child_id` follows automatically.

  Extent-authoritative: assigns `child_id` a fresh extent in the gap after
  `parent_id`'s last child (a fresh node via `interval`, an already-labeled
  subtree via `graft`), so the adjacency is readable by extent order (see
  `children_by_extent/2`) with no separate carve pass.
  """
  @spec append_child(tid, id, id) :: :ok
  def append_child(tid, parent_id, child_id) do
    detach(tid, child_id)
    parent = ensure_extent(tid, parent_id)
    place_child(tid, parent_id, child_id, extent_after_last(tid, parent_id, parent))
    put(tid, child_id, %{fetch!(tid, child_id) | parent: parent_id})
  end

  # Pair each child id with its extent window: none for [], a single interval for one
  # child, a multispan partition for many. Used by `graft_plan` (the move-into-slot plan).
  defp carve_windows([], _a, _b), do: []
  defp carve_windows([only], a, b), do: [{only, Extent.interval(a, b)}]
  defp carve_windows(ids, a, b), do: Enum.zip(ids, Extent.multispan(a, b, length(ids)))

  # Give `child_id` an extent in the `(gap_a, gap_b)` gap under `parent_id`'s tree,
  # writing its `root`/`start`/`stop`. A fresh child (no extent yet) gets a single
  # `interval`; an already-labeled subtree is relocated wholesale by `graft` (its
  # descendants' relative keys preserved, `root` rewritten to the new tree).
  defp place_child(tid, parent_id, child_id, {gap_a, gap_b}) do
    root = fetch!(tid, parent_id).root
    child = fetch!(tid, child_id)

    if child.start == nil do
      {start, stop} = Extent.interval(gap_a, gap_b)
      put(tid, child_id, %{child | root: root, start: start, stop: stop})
    else
      graft_subtree(tid, child_id, child, root, gap_a, gap_b)
    end
  end

  # Relocate the already-labeled subtree rooted at `child_id` into `(gap_a, gap_b)`,
  # rewriting every subtree node's extent (prefix-remap) and its `root`.
  defp graft_subtree(tid, child_id, child, root, gap_a, gap_b) do
    ids = subtree_ids(tid, child_id)
    recs = Enum.map(ids, &fetch!(tid, &1))
    grafted = Extent.graft(recs, child.start, child.stop, gap_a, gap_b)

    Enum.zip(ids, grafted)
    |> Enum.each(fn {id, rec} ->
      put(tid, id, %{fetch!(tid, id) | root: root, start: rec.start, stop: rec.stop})
    end)
  end

  # Ensure `id` carries an extent: a tree root (parent nil) with no extent yet is
  # seeded with the fixed `Extent.root_window/0` (the tree-root extent).
  # Returns the (possibly updated) record.
  defp ensure_extent(tid, id) do
    case fetch!(tid, id) do
      %{start: nil} = data ->
        seeded = %{data | root: id, start: @root_start, stop: @root_stop}
        put(tid, id, seeded)
        seeded

      data ->
        data
    end
  end

  # The gap after `parent`'s current last child: (last_child.stop, parent.stop), or
  # (parent.start, parent.stop) when empty. Order comes from the record extents.
  defp extent_after_last(tid, parent_id, parent_data) do
    a =
      case List.last(children_by_extent(tid, parent_id)) do
        nil -> parent_data.start
        last -> fetch!(tid, last).stop
      end

    {a, parent_data.stop}
  end

  # The gap for a node inserted before `reference_id`: (prev_sibling.stop ||
  # parent.start, reference.start), with the previous sibling found by extent order.
  defp extent_before(tid, parent_id, parent_data, reference_id) do
    before =
      tid
      |> children_by_extent(parent_id)
      |> Enum.take_while(&(&1 != reference_id))

    a = if prev = List.last(before), do: fetch!(tid, prev).stop, else: parent_data.start
    {a, fetch!(tid, reference_id).start}
  end

  # The gap for a node inserted immediately AFTER `reference_id`: (reference.stop,
  # next_sibling.start || parent.stop), by extent order.
  defp extent_after(tid, parent_id, parent_data, reference_id) do
    after_ref =
      tid
      |> children_by_extent(parent_id)
      |> Enum.drop_while(&(&1 != reference_id))
      |> Enum.drop(1)

    b = if next = List.first(after_ref), do: fetch!(tid, next).start, else: parent_data.stop
    {fetch!(tid, reference_id).stop, b}
  end

  @doc """
  Compute (without mutating anything) the plan for moving `child_ids` (in order) under
  `parent_id` at `position` — for the unified `NodeData.rehome` move path, which applies the
  plan to BOTH tables. Returns `{dest_root, dest_parent, extents}` where `dest_root` is the
  parent's tree root, `dest_parent` is `parent_id`, and `extents` is
  `%{node_id => {new_start, new_stop}}` for EVERY node in every moved subtree (the graft
  prefix-swap into each child's carved window). `position`: `:last` | `{:before, ref}`.
  """
  @spec graft_plan(tid, id, [id], :last | {:before, id}) ::
          {id, id, %{optional(id) => {Extent.t(), Extent.t()}}}
  def graft_plan(tid, parent_id, child_ids, position) do
    parent = fetch!(tid, parent_id)
    {gap_a, gap_b} = plan_gap(tid, parent_id, parent, position)

    extents =
      child_ids
      |> carve_windows(gap_a, gap_b)
      |> Enum.reduce(%{}, fn {child_id, {wstart, wstop}}, acc ->
        child = fetch!(tid, child_id)
        ids = subtree_ids(tid, child_id)
        recs = Enum.map(ids, &fetch!(tid, &1))
        grafted = Extent.graft(recs, child.start, child.stop, wstart, wstop)

        Enum.zip(ids, grafted)
        |> Enum.reduce(acc, fn {id, rec}, a -> Map.put(a, id, {rec.start, rec.stop}) end)
      end)

    {parent.root, parent_id, extents}
  end

  defp plan_gap(tid, parent_id, parent, :last), do: extent_after_last(tid, parent_id, parent)

  defp plan_gap(tid, parent_id, parent, {:before, ref}),
    do: extent_before(tid, parent_id, parent, ref)

  @doc """
  Detach `id` from its current parent (no-op when already detached). `id`'s `parent`
  is nilled and its subtree is RE-ROOTED at `id` (its own `.root` -> `id` = itself, its
  descendants' `.root` -> `id`) so the `.root`/extent bookkeeping stays truthful to the
  parent topology — the consistency net asserts `.root` == the walked parent root. The
  caller overwrites `parent`/`root` again on re-attach (via `place_child`/`graft`).
  """
  @spec detach(tid, id) :: :ok
  def detach(tid, id) do
    put(tid, id, %{fetch!(tid, id) | parent: nil, root: id})
    reroot_descendants(tid, id)
    :ok
  end

  # Point every descendant of `id`'s `.root` at `id` (its new tree root). `id` itself
  # is its own root (`root: id`); a tree root has `parent: nil` but `root: self`.
  defp reroot_descendants(tid, id) do
    for descendant <- descendant_ids(tid, id) do
      put(tid, descendant, %{fetch!(tid, descendant) | root: id})
    end

    :ok
  end

  # ==========================================================================
  # Reads (via the DOM.NodeData protocol / record fields)
  # ==========================================================================

  @spec type(tid, id) :: DOM.Node.type()
  def type(tid, id), do: tid |> fetch!(id) |> NodeData.type()

  @spec node_name(tid, id) :: String.t()
  def node_name(tid, id), do: tid |> fetch!(id) |> NodeData.node_name()

  @spec parent(tid, id) :: id | nil
  def parent(tid, id), do: tid |> fetch!(id) |> NodeData.parent()

  @spec children(tid, id) :: [id]
  def children(tid, id), do: children_by_extent(tid, id)

  @doc "A Text/Comment node's value."
  @spec value(tid, id) :: String.t()
  def value(tid, id), do: fetch!(tid, id).value

  @doc "Set a Text/Comment node's value (used for character coalescing)."
  @spec set_value(tid, id, String.t()) :: :ok
  def set_value(tid, id, value), do: put(tid, id, %{fetch!(tid, id) | value: value})

  # ==========================================================================
  # Element attributes / namespace
  # ==========================================================================

  @spec get_attribute(tid, id, String.t()) :: String.t() | nil
  def get_attribute(tid, id, name) do
    case Enum.find(fetch!(tid, id).attributes, fn {key, _v} ->
           NodeData.Element.matches_key?(key, name)
         end) do
      {_key, value} -> value
      nil -> nil
    end
  end

  @spec has_attribute(tid, id, String.t()) :: boolean()
  def has_attribute(tid, id, name) do
    Enum.any?(fetch!(tid, id).attributes, fn {key, _v} ->
      NodeData.Element.matches_key?(key, name)
    end)
  end

  @spec set_attribute(tid, id, String.t(), String.t()) :: :ok
  def set_attribute(tid, id, name, value) do
    element = fetch!(tid, id)
    put(tid, id, %{element | attributes: put_attr_by_name(element.attributes, name, value)})
  end

  # Update the value of the attribute matching qualified `name` (key preserved), or
  # append a plain-keyed attribute when none matches.
  defp put_attr_by_name(attrs, name, value) do
    if Enum.any?(attrs, fn {key, _v} -> NodeData.Element.matches_key?(key, name) end) do
      Enum.map(attrs, &update_attr_value(&1, name, value))
    else
      attrs ++ [{name, value}]
    end
  end

  defp update_attr_value({key, _v} = attr, name, value) do
    if NodeData.Element.matches_key?(key, name), do: {key, value}, else: attr
  end

  @doc "Set `name`=`value` only if the element does not already carry `name`."
  @spec put_attribute_if_absent(tid, id, String.t(), String.t()) :: :ok
  def put_attribute_if_absent(tid, id, name, value) do
    if has_attribute(tid, id, name), do: :ok, else: set_attribute(tid, id, name, value)
  end

  @doc "Remove the attribute matching qualified `name` (a no-op when absent)."
  @spec remove_attribute(tid, id, String.t()) :: :ok
  def remove_attribute(tid, id, name) do
    element = fetch!(tid, id)

    kept =
      Enum.reject(element.attributes, fn {key, _v} -> NodeData.Element.matches_key?(key, name) end)

    put(tid, id, %{element | attributes: kept})
  end

  @spec namespace(tid, id) :: NodeData.Element.namespace() | nil
  def namespace(tid, id) do
    case fetch!(tid, id) do
      %NodeData.Element{namespace: namespace} -> namespace
      _ -> nil
    end
  end

  @doc "A template element's content DocumentFragment id, or nil."
  @spec content(tid, id) :: id | nil
  def content(tid, id) do
    case fetch!(tid, id) do
      %NodeData.Element{content: content} -> content
      _ -> nil
    end
  end

  @doc "An element's shadow root id, or nil."
  @spec shadow_root(tid, id) :: id | nil
  def shadow_root(tid, id) do
    case fetch!(tid, id) do
      %NodeData.Element{shadow_root: shadow_root} -> shadow_root
      _ -> nil
    end
  end

  @doc "A shadow root's host element id, or nil."
  @spec shadow_host(tid, id) :: id | nil
  def shadow_host(tid, id) do
    case fetch!(tid, id) do
      %NodeData.ShadowRoot{host: host} -> host
      _ -> nil
    end
  end

  @doc "A shadow root's mode (`:open`/`:closed`), or nil for a non-shadow-root."
  @spec shadow_mode(tid, id) :: :open | :closed | nil
  def shadow_mode(tid, id) do
    case fetch!(tid, id) do
      %NodeData.ShadowRoot{mode: mode} -> mode
      _ -> nil
    end
  end

  # Record-only clone (nodes tid, no index) — the TEMPORARY seam for DOM.Range.Contents /
  # the tree builder's <template> path, which build a detached tree and let the caller's
  # rehome mirror the index. Remove with the _contents.ex create-in-place rewrite.
  @spec clone_record(tid, id, boolean()) :: id
  def clone_record(nodes, id, deep?) do
    clone_id = make_ref()
    clone_record_subtree(nodes, id, deep?, clone_id, clone_id, nil, @root_start, @root_stop)
    clone_id
  end

  defp clone_record_subtree(nodes, src_id, deep?, clone_id, root, parent, start, stop) do
    put(nodes, clone_id, %{
      fetch!(nodes, src_id)
      | parent: parent,
        root: root,
        start: start,
        stop: stop
    })

    if deep? do
      nodes
      |> children_by_extent(src_id)
      |> Enum.reduce(start, fn src_child, prev ->
        {cstart, cstop} = Extent.interval(prev, stop)
        clone_record_subtree(nodes, src_child, true, make_ref(), root, clone_id, cstart, cstop)
        cstop
      end)
    end
  end

  @doc "Descendant ids of `root_id` in tree (document) order — excludes `root_id`."
  @spec descendant_ids(tid, id) :: [id]
  def descendant_ids(tid, root_id) do
    tid
    |> children_by_extent(root_id)
    |> Enum.flat_map(&subtree_ids(tid, &1))
  end

  @doc "Element descendant ids of `root_id` whose local name matches `name` (`*` = any)."
  @spec elements_by_tag_name(tid, id, String.t()) :: [id]
  def elements_by_tag_name(tid, root_id, name) do
    tid
    |> descendant_ids(root_id)
    |> Enum.filter(&tag_name_match?(tid, &1, name))
  end

  defp subtree_ids(tid, id) do
    [id | tid |> children_by_extent(id) |> Enum.flat_map(&subtree_ids(tid, &1))]
  end

  defp tag_name_match?(tid, id, name) do
    case fetch!(tid, id) do
      %NodeData.Element{local_name: local_name} -> name == "*" or local_name == name
      _ -> false
    end
  end

  @doc """
  Fetch the `{id, record}` rows for exactly the ids in `id_set` (a map used as a set —
  membership is `is_map_key`). One bounded select, no per-id round trip. Backs the
  record-rollup step of `NodeData.rehome`.
  """
  @spec records_of(tid, %{optional(id) => term()}) :: [{id, struct()}]
  def records_of(nodes, id_set) do
    :ets.select(nodes, records_of_spec(id_set))
  end

  @doc """
  Bulk-replace records from `replacements` (`%{id => new_record}`) in ONE `select_replace`:
  a single-clause spec closing over the map (`is_map_key`/`map_get`), so it is independent
  of subtree size. The record key (id) is unchanged, so `select_replace` is legal here (a
  value-only swap). Backs the record-write step of `NodeData.rehome`.
  """
  @spec records_replace(tid, %{optional(id) => struct()}) :: non_neg_integer()
  def records_replace(nodes, replacements) do
    :ets.select_replace(nodes, records_replace_spec(replacements))
  end

  defmatchspec records_of_spec(id_set) do
    {id, _} = entry when is_map_key(id_set, id) -> entry
  end

  defmatchspec records_replace_spec(replacements) do
    {id, _} when is_map_key(replacements, id) -> {id, :erlang.map_get(id, replacements)}
  end

  @doc """
  Ordered child ids of `node_id`, derived purely from the record extents on the
  nodes tid (children are the rows whose `parent` is `node_id`, in `start` order)
  — the index-free adjacency read the tree builder uses while it has no index in
  scope. O(n) scan; the span-row read (`span_children_of/3`) is the O(log n + m)
  path where an index is available.
  """
  @spec children_by_extent(tid, id) :: [id]
  def children_by_extent(nodes, node_id) do
    nodes
    |> :ets.select(children_by_extent_spec(node_id))
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defmatchspecp children_by_extent_spec(node_id) do
    {id, %{parent: ^node_id, start: start}} -> {start, id}
  end

  @doc """
  The maximum valid Range boundary offset for `node_id`: the child count for an
  element/document/fragment container, the value length for text/comment.
  """
  @spec max_boundary_offset(tid, id) :: non_neg_integer()
  def max_boundary_offset(nodes, node_id) do
    case fetch!(nodes, node_id) do
      %{value: value} when is_binary(value) -> String.length(value)
      _ -> length(children_by_extent(nodes, node_id))
    end
  end

  @doc """
  The id of the node whose extent `start` key equals `extent_key` (the container a
  range boundary pins to), or `nil`. Reverse of the boundary normalization.
  """
  @spec node_at_start_key(tid, Extent.t()) :: id | nil
  def node_at_start_key(nodes, extent_key) do
    case :ets.select(nodes, node_at_start_key_spec(extent_key)) do
      [id | _] -> id
      [] -> nil
    end
  end

  defmatchspecp node_at_start_key_spec(extent_key) do
    {id, %{start: ^extent_key}} -> id
  end
end
