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
  the extents (`DOM.NodeData.NodesTable.children_by_extent/2`).
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
  alias DOM.NodeData.Extent
  alias DOM.NodeData.IndexTable
  alias DOM.NodeData.NodesTable

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
    IndexTable.span_put(index, id, %{
      root: node_data.root,
      parent: node_data.parent,
      start: node_data.start,
      stop: node_data.stop,
      type: mod.type(node_data)
    })

    # element membership rows (tag/id/class/attr) — dispatch by module, not a struct
    # literal, to avoid a compile-time cycle (the struct modules `use DOM.NodeData`).
    if mod == DOM.NodeData.Element,
      do: IndexTable.index_put(index, id, node_data)

    :ets.insert(nodes, {id, node_data})
    id
  end

  @doc """
  Relocate the subtree in span-index window `{root, start, stop}` by applying `transform`
  to each of its span rows, then reflecting the result onto the node records. Cross-table
  and atomic w.r.t. one op. `transform` takes/returns a raw span row tuple.
  """
  @spec rehome(:ets.tid(), :ets.tid(), {term(), Extent.t(), Extent.t()}, (tuple() -> tuple())) ::
          :ok
  def rehome(nodes, index, {root, start, stop}, transform) do
    rows = IndexTable.span_window(index, root, start, stop)
    IndexTable.span_window_delete(index, root, start, stop)
    {new_index_rows, node_ids} = rehome_transform(rows, transform, [], %{})
    :ets.insert(index, new_index_rows)

    entries = Map.new(NodesTable.records_of(nodes, node_ids))
    replacements = Enum.reduce(new_index_rows, entries, &merge_span_row/2)
    NodesTable.records_replace(nodes, replacements)

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
    child = NodesTable.fetch!(nodes, child_id)

    rehome(nodes, index, {child.root, child.start, child.stop}, fn
      {{:span, _root, key, kind, _parent}, {^child_id, type}} ->
        {{:span, child_id, key, kind, nil}, {child_id, type}}

      {{:span, _root, key, kind, parent}, val} ->
        {{:span, child_id, key, kind, parent}, val}
    end)
  end

  @doc """
  Move `child_ids` (in order) under `parent_id` at `position` (`:last` | `{:before, ref}`) —
  the `rehome` into a parent slot. `NodesTable.graft_plan` computes the destination (all the
  prefix-swap key math, single source of truth); this applies it to BOTH tables via `rehome`,
  one call per moved child subtree. Each node gets its new `start`/`stop` from the plan, its
  `root` → the dest tree root, and each moved child's OWN root → `parent_id` (descendants keep
  their parent).
  """
  @spec graft_into(
          :ets.tid(),
          :ets.tid(),
          reference(),
          [reference()],
          :last | {:before, reference()}
        ) ::
          :ok
  def graft_into(nodes, index, parent_id, child_ids, position) do
    {dest_root, dest_parent, extents} =
      NodesTable.graft_plan(nodes, parent_id, child_ids, position)

    Enum.each(child_ids, fn child_id ->
      child = NodesTable.fetch!(nodes, child_id)

      rehome(nodes, index, {child.root, child.start, child.stop}, fn
        {{:span, _root, _key, kind, _parent}, {^child_id, type}} ->
          {start, stop} = Map.fetch!(extents, child_id)
          {{:span, dest_root, key_for(kind, start, stop), kind, dest_parent}, {child_id, type}}

        {{:span, _root, _key, kind, parent}, {id, type}} ->
          {start, stop} = Map.fetch!(extents, id)
          {{:span, dest_root, key_for(kind, start, stop), kind, parent}, {id, type}}
      end)
    end)
  end

  defp key_for(:start, start, _stop), do: start
  defp key_for(:stop, _start, stop), do: stop

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

  # ==========================================================================
  # Node creation (cross-table: writes the record AND its index rows, index-first)
  # ==========================================================================
  #
  # Each `create_*` mints an id, builds the full labeled record (root: id, the fixed root
  # window), and `insert/4`s it into both tables. A created node is a labeled 1-node tree.

  # `struct!(Module, fields)` (not a `%Module{}` literal) keeps the struct reference at
  # RUNTIME, not compile time — the struct modules `use DOM.NodeData`, so a compile-time
  # literal here would deadlock the protocol on its own implementers.

  @spec create_element(:ets.tid(), :ets.tid(), String.t()) :: reference()
  def create_element(nodes, index, local_name) do
    id = make_ref()
    {start, stop} = Extent.root_window()

    record =
      struct!(DOM.NodeData.Element, local_name: local_name, root: id, start: start, stop: stop)

    insert(id, record, nodes, index)
  end

  @spec create_element_ns(:ets.tid(), :ets.tid(), String.t(), atom(), [
          {String.t(), String.t()}
        ]) :: reference()
  def create_element_ns(nodes, index, local_name, namespace, attributes) do
    id = make_ref()
    {start, stop} = Extent.root_window()

    record =
      struct!(DOM.NodeData.Element,
        local_name: local_name,
        namespace: namespace,
        attributes: attributes,
        root: id,
        start: start,
        stop: stop
      )

    insert(id, record, nodes, index)
  end

  @spec create_text(:ets.tid(), :ets.tid(), String.t()) :: reference()
  def create_text(nodes, index, value) do
    id = make_ref()
    {start, stop} = Extent.root_window()

    insert(
      id,
      struct!(DOM.NodeData.Text, value: value, root: id, start: start, stop: stop),
      nodes,
      index
    )
  end

  @spec create_comment(:ets.tid(), :ets.tid(), String.t()) :: reference()
  def create_comment(nodes, index, value) do
    id = make_ref()
    {start, stop} = Extent.root_window()

    insert(
      id,
      struct!(DOM.NodeData.Comment, value: value, root: id, start: start, stop: stop),
      nodes,
      index
    )
  end

  @spec create_doctype(:ets.tid(), :ets.tid(), String.t(), String.t() | nil, String.t() | nil) ::
          reference()
  def create_doctype(nodes, index, name, public_id, system_id) do
    id = make_ref()
    {start, stop} = Extent.root_window()

    record =
      struct!(DOM.NodeData.DocumentType,
        name: name,
        public_id: public_id,
        system_id: system_id,
        root: id,
        start: start,
        stop: stop
      )

    insert(id, record, nodes, index)
  end

  @spec create_document(:ets.tid(), :ets.tid()) :: reference()
  def create_document(nodes, index) do
    id = make_ref()
    {start, stop} = Extent.root_window()
    insert(id, struct!(DOM.NodeData.Document, root: id, start: start, stop: stop), nodes, index)
  end

  @spec create_document_fragment(:ets.tid(), :ets.tid()) :: reference()
  def create_document_fragment(nodes, index) do
    id = make_ref()
    {start, stop} = Extent.root_window()

    insert(
      id,
      struct!(DOM.NodeData.DocumentFragment, root: id, start: start, stop: stop),
      nodes,
      index
    )
  end

  @doc """
  Create a template element together with its "template contents" DocumentFragment,
  linked via the element's `content` field. Returns `{template_id, content_id}`.
  """
  @spec create_template(:ets.tid(), :ets.tid(), [{String.t(), String.t()}]) ::
          {reference(), reference()}
  def create_template(nodes, index, attributes) do
    content_id = make_ref()
    {start, stop} = Extent.root_window()

    insert(
      content_id,
      struct!(DOM.NodeData.DocumentFragment, root: content_id, start: start, stop: stop),
      nodes,
      index
    )

    template_id = make_ref()

    record =
      struct!(DOM.NodeData.Element,
        local_name: "template",
        attributes: attributes,
        content: content_id,
        root: template_id,
        start: start,
        stop: stop
      )

    insert(template_id, record, nodes, index)
    {template_id, content_id}
  end

  @doc """
  Create a node as a child of `parent_id` **directly in its final slot** (create-in-place).
  `NodesTable.carve_slot` computes the child's `{root, {start, stop}}` in the parent's gap;
  `build.(id, {start, stop})` makes the FINAL record (real extent, parent linked); `insert/4`
  writes both tables. `position`: `:last` | `{:before, ref}` | `{:after, ref}`.
  """
  @spec create_child(
          :ets.tid(),
          :ets.tid(),
          reference(),
          (reference(), {Extent.t(), Extent.t()} -> t()),
          :last | {:before, reference()} | {:after, reference()}
        ) :: reference()
  def create_child(nodes, index, parent_id, build, position) do
    id = make_ref()
    {_root, {start, stop}} = NodesTable.carve_slot(nodes, parent_id, position)
    insert(id, build.(id, {start, stop}), nodes, index)
  end

  @doc """
  Attach a shadow root to `host_id`: create a detached `ShadowRoot` node (in both tables) and
  back-link it on the host element. Returns the shadow root id.
  """
  @spec create_shadow_root(:ets.tid(), :ets.tid(), reference(), :open | :closed, :named | :manual) ::
          reference()
  def create_shadow_root(nodes, index, host_id, mode, slot_assignment \\ :named) do
    shadow_id = make_ref()
    {start, stop} = Extent.root_window()

    record =
      struct!(DOM.NodeData.ShadowRoot,
        host: host_id,
        mode: mode,
        slot_assignment: slot_assignment,
        root: shadow_id,
        start: start,
        stop: stop
      )

    insert(shadow_id, record, nodes, index)

    host = NodesTable.fetch!(nodes, host_id)
    NodesTable.put(nodes, host_id, %{host | shadow_root: shadow_id})
    shadow_id
  end

  @doc """
  Clone the node (deep when `deep?`) as a detached, fully-labeled subtree written into BOTH
  tables; returns the new id. The clone is its own tree (the fixed `Extent.root_window/0`,
  descendants carved inside from the SOURCE's extent order).
  """
  @spec clone(:ets.tid(), :ets.tid(), reference(), boolean()) :: reference()
  def clone(nodes, index, id, deep?) do
    clone_id = make_ref()
    {start, stop} = Extent.root_window()
    clone_subtree(nodes, index, id, deep?, clone_id, clone_id, nil, {start, stop})
    clone_id
  end

  # Copy `src_id`'s record onto `clone_id` with the given extent (tree `root`, `parent`),
  # write it into BOTH tables via `insert/4`, then (deep) clone its source children in extent
  # order, carving each into a fresh sub-interval. Order from the source's extents.
  defp clone_subtree(nodes, index, src_id, deep?, clone_id, root, parent, {start, stop}) do
    record = %{
      NodesTable.fetch!(nodes, src_id)
      | parent: parent,
        root: root,
        start: start,
        stop: stop
    }

    insert(clone_id, record, nodes, index)

    if deep? do
      nodes
      |> NodesTable.children_by_extent(src_id)
      |> Enum.reduce(start, fn src_child, prev ->
        {cstart, cstop} = Extent.interval(prev, stop)
        clone_subtree(nodes, index, src_child, true, make_ref(), root, clone_id, {cstart, cstop})
        cstop
      end)
    end
  end

  # ==========================================================================
  # Span reads that need a record extent (cross-table: read nodes, then index)
  # ==========================================================================

  @doc "Ordered child ids of `node_id`, read from its record's extent + span rows."
  @spec span_children_of(:ets.tid(), :ets.tid(), reference()) :: [reference()]
  def span_children_of(nodes, index, node_id) do
    node = NodesTable.fetch!(nodes, node_id)
    IndexTable.span_children(index, node.root, node_id, node.start, node.stop)
  end

  @doc "Ordered ELEMENT child ids of `node_id` (backs `ParentNode.children`)."
  @spec span_element_children_of(:ets.tid(), :ets.tid(), reference()) :: [reference()]
  def span_element_children_of(nodes, index, node_id) do
    node = NodesTable.fetch!(nodes, node_id)
    IndexTable.span_element_children(index, node.root, node_id, node.start, node.stop)
  end

  @doc """
  (Re)build EVERY labeled node's span rows in `index` straight from its record extent — the
  bulk mirror used by the parse / bulk-load path (the incremental path is `rehome`). O(n).
  """
  @spec span_index_all(:ets.tid(), :ets.tid()) :: :ok
  def span_index_all(nodes, index) do
    for {id, %{start: start} = data} when start != nil <- :ets.tab2list(nodes) do
      IndexTable.span_mirror_one(index, id, data)
    end

    :ok
  end

  # ==========================================================================
  # Consistency net (cross-table: reads both tables between operations)
  # ==========================================================================

  @doc """
  Assert the document's ETS invariants, returning `:ok` or raising. Adjacency integrity (the
  nested-set extents are a valid tree and the span rows mirror the record extents) always; id
  index agreement (index rows mirror element memberships) when an `index` tid is given. Meant
  to run BETWEEN operations (an `on_exit` hook), never mid-operation.
  """
  @spec check_consistency!(:ets.tid()) :: :ok
  @spec check_consistency!(:ets.tid(), :ets.tid()) :: :ok
  def check_consistency!(nodes, index \\ nil) do
    rows = :ets.tab2list(nodes)

    if index do
      check_index!(rows, index)
      check_roots!(rows)
      check_spans!(rows, index)
      check_ranges!(rows, index)
      check_slots!(rows, index)
      check_listeners!(rows, index)
      check_microtasks!(index)
    end

    :ok
  end

  # Root ↔ topology: every node's `.root` must equal the root reached by walking `.parent`.
  defp check_roots!(rows) do
    by_id = Map.new(rows)

    for {id, data} <- rows do
      walked = walked_root(by_id, id)
      stored = data.root

      unless walked == stored do
        raise "root drift: #{inspect(id)} stores root #{inspect(stored)} " <>
                "but its parent chain reaches #{inspect(walked)}"
      end
    end

    :ok
  end

  defp walked_root(by_id, id) do
    case Map.fetch!(by_id, id) do
      %{parent: nil} -> id
      %{parent: parent} -> walked_root(by_id, parent)
    end
  end

  # Listener consistency: every :listener row must reference a live node — OR a live
  # AbortSignal (an AbortSignal is an EventTarget whose `abort`-event listeners are
  # stored in :listener rows keyed by the signal ref, not a node id).
  defp check_listeners!(rows, index) do
    live = MapSet.new(rows, fn {id, _data} -> id end)

    dangling =
      for {{:listener, target_id, _seq}, _listener} <- IndexTable.index_rows_of(index, :listener),
          not MapSet.member?(live, target_id),
          IndexTable.abort_signal_get(index, target_id) == nil,
          do: target_id

    if dangling != [] do
      raise "dangling listener rows for dead nodes: #{inspect(Enum.uniq(dangling))}"
    end
  end

  # Microtask consistency: OUTSIDE a checkpoint drain the queue must be empty.
  defp check_microtasks!(index) do
    pending = IndexTable.index_rows_of(index, :microtask)

    if pending != [] do
      raise "undrained microtask rows outside a checkpoint: #{inspect(pending)}"
    end
  end

  # Range boundary consistency: every :range_* row pins to a live container at a valid offset.
  defp check_ranges!(rows, index) do
    by_start = Map.new(rows, fn {id, data} -> {Map.get(data, :start), {id, data}} end)
    Enum.each(IndexTable.range_all_rows(index), &check_range_row!(&1, rows, by_start))
  end

  # Slot assignment consistency: :slot / :assigned rows reference live nodes and agree.
  defp check_slots!(rows, index) do
    live = MapSet.new(rows, fn {id, _data} -> id end)

    slot_pairs =
      for {{:slot, slot_id, _pos}, node_id} <- IndexTable.index_rows_of(index, :slot),
          do: {slot_id, node_id}

    assigned =
      for {{:assigned, node_id}, slot_id} <- IndexTable.index_rows_of(index, :assigned),
          into: %{},
          do: {node_id, slot_id}

    Enum.each(slot_pairs, fn {slot_id, node_id} ->
      unless MapSet.member?(live, slot_id) and MapSet.member?(live, node_id) do
        raise "dangling slot row: #{inspect({slot_id, node_id})} references a missing node"
      end

      if Map.get(assigned, node_id) != slot_id do
        raise "slot rows disagree: #{inspect(node_id)} assigned to " <>
                "#{inspect(Map.get(assigned, node_id))} but slot-listed under #{inspect(slot_id)}"
      end
    end)
  end

  defp check_range_row!({kind, extent_key, ref, offset}, rows, by_start) do
    case Map.get(by_start, extent_key) do
      nil ->
        raise "dangling range boundary: #{kind} of #{inspect(ref)} at " <>
                "#{inspect(extent_key)} pins to no live node"

      {id, data} ->
        max = check_max_offset(rows, id, data)

        unless offset >= 0 and offset <= max do
          raise "range offset out of bounds: #{kind} of #{inspect(ref)} " <>
                  "offset #{offset} > max #{max} for #{inspect(id)}"
        end
    end
  end

  defp check_max_offset(_rows, _id, %{value: value}) when is_binary(value),
    do: String.length(value)

  defp check_max_offset(rows, id, _data) do
    Enum.count(rows, fn {_cid, cdata} -> Map.get(cdata, :parent) == id end)
  end

  # Span (extent) consistency: backward (span ids exist), containment (nested), mirror (span
  # rows == record extents), and every node labeled.
  defp check_spans!(rows, index) do
    node_ids = MapSet.new(rows, fn {id, _data} -> id end)
    spans = IndexTable.span_rows(index)

    check_extents_present!(rows)
    check_spans_backward!(spans, node_ids)
    check_spans_mirror!(rows, spans)
    by_id = Map.new(rows)
    Enum.each(rows, fn {id, data} -> check_node_containment!(id, data, by_id) end)
  end

  # labeling: EVERY node carries an extent (start/stop non-nil) — labeled from creation.
  defp check_extents_present!(rows) do
    Enum.each(rows, fn {id, data} ->
      if data.start == nil or data.stop == nil do
        raise "unlabeled node: #{inspect(id)} has no extent " <>
                "(#{inspect(data.start)}..#{inspect(data.stop)}) — " <>
                "every node must be labeled from creation"
      end
    end)
  end

  # backward: no span row points at a node that isn't in the table.
  defp check_spans_backward!(spans, node_ids) do
    Enum.each(spans, fn {_root, _key, _kind, parent, node_id, _type} ->
      unless MapSet.member?(node_ids, node_id) do
        raise "dangling span: node #{inspect(node_id)} not in the nodes table"
      end

      if parent != nil and not MapSet.member?(node_ids, parent) do
        raise "dangling span: parent #{inspect(parent)} not in the nodes table"
      end
    end)
  end

  # mirror: the span rows are exactly the two rows per labeled record extent.
  defp check_spans_mirror!(rows, spans) do
    expected =
      for {id, %{start: start} = data} <- rows,
          start != nil,
          kind_key <- [{start, :start}, {data.stop, :stop}] do
        {key, kind} = kind_key
        {data.root, key, kind, data.parent, id, type(data)}
      end

    if Enum.sort(expected) != Enum.sort(spans) do
      raise "span rows disagree with record extents: " <>
              "expected #{inspect(Enum.sort(expected))}, got #{inspect(Enum.sort(spans))}"
    end
  end

  # containment: each of `id`'s extent-children sits strictly inside its window.
  defp check_node_containment!(id, data, by_id) do
    {start, stop} = {data.start, data.stop}

    for {kid, k} <- by_id, k.parent == id do
      unless start < k.start and k.start < k.stop and k.stop < stop do
        raise "extent containment violated: child #{inspect(kid)} " <>
                "#{inspect({k.start, k.stop})} not inside " <>
                "#{inspect(id)} #{inspect({start, stop})}"
      end
    end
  end

  # id index: the membership rows equal, exactly, the memberships of every element record.
  # Match `%mod{}` + `mod ==` (not a struct pattern) to avoid a compile-time dep on the
  # Element struct module, which `use`s this protocol.
  defp check_index!(rows, index) do
    expected =
      for {node_id, %mod{} = element} when mod == DOM.NodeData.Element <- rows,
          membership <- IndexTable.memberships(element),
          do: {membership, node_id}

    actual =
      for kind <- [:tag, :id, :class, :attr],
          {key, node_id} <- IndexTable.index_rows_of(index, kind),
          do: {drop_ref(key), node_id}

    if Enum.sort(expected) != Enum.sort(actual) do
      raise "inconsistent index: expected #{inspect(Enum.sort(expected))}, " <>
              "got #{inspect(Enum.sort(actual))}"
    end
  end

  # An index row key minus its trailing membership ref (its {kind, value…} head).
  defp drop_ref(key) do
    key |> Tuple.to_list() |> Enum.drop(-1) |> List.to_tuple()
  end
end
