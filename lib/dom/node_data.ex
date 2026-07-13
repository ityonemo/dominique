use Protoss

defprotocol DOM.NodeData do
  @moduledoc """
  The internal per-type node records stored in a document's ETS table, one
  struct per node kind (`DOM.NodeData.Element`, `Text`, `Comment`, `Document`,
  `DocumentFragment`, `DocumentType`). Never exposed to callers — user code holds
  `DOM.Node` handles; the server reads these structs out of the tuple space.

  The protocol carries the per-kind values the server dispatches on: the handle
  `type` atom, the DOM `nodeType` number, and the DOM `nodeName`. Structural
  fields (`parent`, `value`, `attributes`, `local_name`, the nested-set extent
  `root`/`start`/`stop`) are read as plain struct fields; `parent/1` in the `after`
  block wraps the common one. Child adjacency is NOT a field — it is derived from
  the extents (`DOM.NodeData.Table.children_by_extent/2`).
  """

  @type t ::
          DOM.NodeData.Element.t()
          | DOM.NodeData.Text.t()
          | DOM.NodeData.Comment.t()
          | DOM.NodeData.Document.t()
          | DOM.NodeData.DocumentFragment.t()
          | DOM.NodeData.DocumentType.t()

  @doc "The `DOM.Node` handle `type` atom (`:element`, `:text`, …)."
  def type(node_data)

  @doc "The DOM `nodeType` numeric constant."
  def node_type(node_data)

  @doc "The DOM `nodeName`."
  def node_name(node_data)
after
  defmacro __using__(_) do
    quote do
      @enforce_keys ~w[root start stop]a
    end
  end

  @doc "Parent id of the record, or `nil`."
  def parent(%{parent: parent}), do: parent

  # Re-entrant twins of DOM._select_nodes/_select_index: when a read runs INSIDE
  # the document server (e.g. an event listener during dispatch), a GenServer.call
  # back into the same process would deadlock, so read the tid straight from the
  # process dictionary (stashed in DOM.init) and run the select in place. `server`
  # is ignored — the tables are process-ambient here.
  def _select_nodes(_server, select) do
    :nodes
    |> Process.get()
    |> :ets.select(select)
  end

  def _select_index(_server, select) do
    :index
    |> Process.get()
    |> :ets.select(select)
  end

  @spec insert(reference(), t, :ets.tid(), :ets.tid()) :: reference()
  @doc """
  Insert a single fully-built node record for `id` into both tables, INDEX FIRST: its span
  rows (and, for an element, its tag/id/class/attr membership rows), then the record in the
  nodes table. Works for a tree root (`root == id`) or a carved child (`root ==` the tree
  root, `parent ==` its parent) — the relocation fields are read straight off the record.
  Returns `id`.
  """
  def insert(id, %mod{} = node_data, nodes, index) do
    DOM.NodeData.Table.span_put(index, id, %{
      root: node_data.root,
      parent: node_data.parent,
      start: node_data.start,
      stop: node_data.stop,
      type: mod.type(node_data)
    })

    # element membership rows (tag/id/class/attr) — dispatch by module, not a struct
    # literal, to avoid a compile-time cycle (the struct modules `use DOM.NodeData`).
    if mod == DOM.NodeData.Element,
      do: DOM.NodeData.Table.index_put(index, id, node_data)

    :ets.insert(nodes, {id, node_data})
    id
  end

  @doc """
  Relocate the subtree in span-index window `{root, start, stop}` by applying `transform`
  to each of its span rows, then reflecting the result onto the node records. Cross-table
  and atomic w.r.t. one op. `transform` takes/returns a raw span row tuple.
  """
  @spec rehome(:ets.tid(), :ets.tid(), {term(), binary(), binary()}, (tuple() -> tuple())) :: :ok
  def rehome(nodes, index, {root, start, stop}, transform) do
    rows = DOM.NodeData.Table.span_window(index, root, start, stop)
    DOM.NodeData.Table.span_window_delete(index, root, start, stop)
    {new_index_rows, node_ids} = rehome_transform(rows, transform, [], %{})
    :ets.insert(index, new_index_rows)

    entries = Map.new(DOM.NodeData.Table.records_of(nodes, node_ids))
    replacements = Enum.reduce(new_index_rows, entries, &merge_span_row/2)
    DOM.NodeData.Table.records_replace(nodes, replacements)

    :ok
  end

  @doc """
  Detach the subtree rooted at `child_id` from its parent — the `rehome` whose destination
  is the subtree's OWN self-root. Keeps every node's `start`/`stop` byte-keys (the nested-set
  coordinates survive detach); rewrites `root` → `child_id` for the whole subtree, and the
  subtree root's own `parent` → nil. Records + index rows both follow.
  """
  @spec detach(:ets.tid(), :ets.tid(), reference()) :: :ok
  def detach(nodes, index, child_id) do
    child = DOM.NodeData.Table.fetch!(nodes, child_id)

    rehome(nodes, index, {child.root, child.start, child.stop}, fn
      {{:span, _root, key, kind, _parent}, {^child_id, type}} ->
        {{:span, child_id, key, kind, nil}, {child_id, type}}

      {{:span, _root, key, kind, parent}, val} ->
        {{:span, child_id, key, kind, parent}, val}
    end)
  end

  # Merge one transformed span row's relocation fields onto the node's record in the
  # rollup map. A node contributes two rows (:start, :stop): both agree on root/parent;
  # the :start row supplies `start`, the :stop row supplies `stop`. `root == self` is the
  # ONE convention for both tables, so the span row's `root` column is stored verbatim.
  defp merge_span_row({{:span, new_root, key, :start, new_parent}, {id, _type}}, entries) do
    record =
      entries |> Map.fetch!(id) |> Map.merge(%{root: new_root, parent: new_parent, start: key})

    Map.replace!(entries, id, record)
  end

  defp merge_span_row({{:span, _new_root, key, :stop, _new_parent}, {id, _type}}, entries) do
    Map.replace!(entries, id, %{Map.fetch!(entries, id) | stop: key})
  end

  # (3) recursive transform of the grabbed rows — prepend, no Enum/reverse.
  defp rehome_transform([], _transform, rows, ids), do: {rows, ids}

  defp rehome_transform([{_, {id, _type}} = row | rest], transform, rows, ids),
    do: rehome_transform(rest, transform, [transform.(row) | rows], Map.put(ids, id, []))
end
