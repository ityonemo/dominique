defmodule DOM do
  @moduledoc """
  A DOM document backed by a `GenServer` that owns a private ETS table of
  per-type `DOM.NodeData.*` records.

  Node handles are the single `DOM.Node` struct (`%DOM.Node{server, node_id, type}`),
  immutable references carrying the owning server, a node id, and the node kind;
  they are not live objects. Mutating operations run inside the server and may
  transfer whole subtrees between documents, after which a retained handle can
  become stale (see the README).

  Operations are partitioned by scope: **generic** node operations live on
  `DOM.Node`, **element-intrinsic** operations (`local_name`, the attribute API)
  on `DOM.Element`, and **whole-document / query** operations (creating nodes,
  `get_element_by_id/2`, `query_selector/2`, `matches/2`, …) here on `DOM`, which
  is also the GenServer holding every `*_impl`. Cross-module calls into the
  server go through the `_`-prefixed bridges in this module.
  """

  use GenServer
  use MatchSpec

  alias DOM.HTML.TreeBuilder
  alias DOM.Node
  alias DOM.NodeData
  alias DOM.NodeData.Table

  # ==========================================================================
  # Types
  # ==========================================================================

  @enforce_keys [:nodes, :index, :document_id]
  defstruct [:nodes, :index, :document_id, :fragment_root]

  @type state :: %__MODULE__{
          nodes: :ets.tid(),
          index: :ets.tid(),
          document_id: reference(),
          fragment_root: reference() | nil
        }

  @type t :: Node.t()

  # ==========================================================================
  # Lifecycle
  # ==========================================================================

  @doc """
  Start a document server. This is the primary entry point.

  Options: `:document_id` (required — the Document node's id); optional `:parse`
  (a decoded token list) or `:fragment` (`{tokens, context}`). When a build option
  is given, the tree is built into this server's own ETS table in a
  `handle_continue`, in-process, before the server serves any request.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    document_id = Keyword.fetch!(opts, :document_id)
    nodes = :ets.new(__MODULE__, [:set, :private])
    index = :ets.new(:"#{__MODULE__}.Index", [:ordered_set, :private])
    :ets.insert(nodes, {document_id, %NodeData.Document{}})
    state = %__MODULE__{nodes: nodes, index: index, document_id: document_id}

    case build_continue(opts) do
      nil -> {:ok, state}
      continue -> {:ok, state, {:continue, continue}}
    end
  end

  defp build_continue(opts) do
    cond do
      tokens = opts[:parse] -> {:parse, tokens}
      fragment = opts[:fragment] -> {:fragment, fragment}
      :else -> nil
    end
  end

  # ==========================================================================
  # API
  # ==========================================================================

  @spec new(String.t() | nil) :: t()
  @spec create_element(t(), String.t()) :: Node.t()
  @spec create_text_node(t(), String.t()) :: Node.t()
  @spec create_comment(t(), String.t()) :: Node.t()
  @spec create_document_fragment(t()) :: Node.t()
  @spec create_document_type(t(), String.t(), String.t(), String.t()) :: Node.t()
  @spec get_elements_by_tag_name(Node.t(), String.t()) :: [Node.t()]
  @spec get_element_by_id(t(), String.t()) :: Node.t() | nil
  @spec get_elements_by_class_name(Node.t(), String.t()) :: [Node.t()]
  @spec query_selector(Node.t(), String.t()) :: Node.t() | nil
  @spec query_selector_all(Node.t(), String.t()) :: [Node.t()]
  @spec matches(Node.t(), String.t()) :: boolean()
  @spec _select(GenServer.server(), :ets.match_spec()) :: [term()]
  @spec _select_replace(GenServer.server(), :ets.match_spec()) :: non_neg_integer()
  @spec _atomic_ets_op(GenServer.server(), (:ets.tid(), :ets.tid() -> result)) :: result
        when result: term()
  @spec _node_append_child(GenServer.server(), reference(), Node.t()) :: Node.t()
  @spec _node_insert_before(GenServer.server(), reference(), Node.t(), Node.t() | nil) :: Node.t()
  @spec _node_remove_child(GenServer.server(), reference(), Node.t()) :: Node.t()
  @spec _node_replace_child(GenServer.server(), reference(), Node.t(), Node.t()) :: Node.t()
  @spec _node_owner_document(GenServer.server(), reference()) :: Node.t() | nil
  @spec _node_clone_node(GenServer.server(), reference(), boolean()) :: Node.t()
  @spec _export_subtree(GenServer.server(), reference()) :: [{reference(), NodeData.t()}]
  @spec _remove_subtree(GenServer.server(), reference()) :: :ok
  @spec _element_inner_html(GenServer.server(), reference()) :: String.t()
  @spec _element_set_inner_html(GenServer.server(), reference(), String.t()) :: :ok
  @spec _element_set_outer_html(GenServer.server(), reference(), String.t()) :: :ok
  @spec _element_outer_html(GenServer.server(), reference()) :: String.t()
  @spec _node_text_content(GenServer.server(), reference()) :: String.t()
  @spec _node_set_text_content(GenServer.server(), reference(), String.t()) :: :ok
  @spec _node_set_value(GenServer.server(), reference(), String.t()) :: :ok

  # ==========================================================================
  # Implementations
  # ==========================================================================

  @doc """
  Convenience over `start_link/1`: create a document and return its handle. With
  no argument the document is empty; given an HTML string it is parsed (WHATWG
  tree construction) into the document's table before it is returned. Prefer
  `start_link/1` directly (e.g. under a supervisor); this wraps it and mints the
  `%DOM.Node{type: :document}` handle.
  """
  def new(html \\ nil)

  def new(nil), do: new_document(document_id: make_ref())

  def new(html) when is_binary(html),
    do: new_document(document_id: make_ref(), parse: DOM.HTML.tokens(html))

  defp new_document(opts) do
    {:ok, server} = start_link(opts)
    %Node{server: server, node_id: Keyword.fetch!(opts, :document_id), type: :document}
  end

  def create_element(document, local_name) do
    create(document, %NodeData.Element{local_name: local_name})
  end

  @doc false
  # Internal: build an element with an explicit namespace and pre-adjusted
  # attribute list in one hop (used by the HTML tree builder for foreign
  # content). Attributes are stored verbatim — no name normalization.
  def _create_element_ns(document, local_name, namespace, attributes) do
    create(document, %NodeData.Element{
      local_name: local_name,
      namespace: namespace,
      attributes: attributes
    })
  end

  @doc false
  # Internal: the DocumentFragment holding a template element's contents.
  def _element_content(%Node{server: server, node_id: node_id}) do
    GenServer.call(server, {:element_content, node_id})
  end

  def create_text_node(document, value), do: create(document, %NodeData.Text{value: value})

  def create_comment(document, value), do: create(document, %NodeData.Comment{value: value})

  def create_document_fragment(document), do: create(document, %NodeData.DocumentFragment{})

  def create_document_type(document, name, public_id, system_id) do
    node_data = %NodeData.DocumentType{name: name, public_id: public_id, system_id: system_id}
    create(document, node_data)
  end

  defp create(%Node{type: :document} = document, node_data) do
    GenServer.call(document.server, {:create, node_data})
  end

  defp create(%Node{}, _node_data), do: raise(DOM.HierarchyRequestError)

  def get_elements_by_tag_name(document, name) do
    GenServer.call(document.server, {:get_elements_by_tag_name, document.node_id, name})
  end

  def get_element_by_id(document, id) do
    GenServer.call(document.server, {:get_element_by_id, document.node_id, id})
  end

  def get_elements_by_class_name(document, names) do
    GenServer.call(document.server, {:get_elements_by_class_name, document.node_id, names})
  end

  def query_selector(document, selector) do
    GenServer.call(
      document.server,
      {:query_selector, document.node_id, parse_selector!(selector)}
    )
  end

  def query_selector_all(document, selector) do
    GenServer.call(
      document.server,
      {:query_selector_all, document.node_id, parse_selector!(selector)}
    )
  end

  def matches(node, selector) do
    GenServer.call(node.server, {:matches, node.node_id, parse_selector!(selector)})
  end

  # Parse and validate a selector in the CALLER's process, so a malformed or
  # namespace-invalid selector raises `ArgumentError` here rather than crashing
  # the document server. The server receives the ready AST and never re-parses.
  defp parse_selector!(selector) do
    selector |> DOM.CSS.parse() |> DOM.CSS.validate!()
  end

  defp fragment_root_impl(_from, state) do
    {:reply, state.fragment_root, state}
  end

  # Build the parsed tree directly into this server's ETS table, in-process (via
  # DOM.NodeData.Table — no GenServer round-trips), before it serves any request.
  # handle_continue impls take no `from`.
  defp parse_impl(tokens, state) do
    TreeBuilder.build_into(state.nodes, state.index, state.document_id, tokens)
    Table.span_index_all(state.nodes, state.index)
    {:noreply, state}
  end

  defp fragment_impl(tokens, context, state) do
    root_id =
      TreeBuilder.build_fragment_into(
        state.nodes,
        state.index,
        state.document_id,
        tokens,
        context
      )

    Table.span_index_all(state.nodes, state.index)
    {:noreply, %{state | fragment_root: root_id}}
  end

  defp create_impl(node_data, _from, state) do
    node_id = make_ref()
    Table.put(state.nodes, node_id, node_data)
    index_element(state.index, node_id, node_data)
    {:reply, node_handle(state.nodes, node_id), state}
  end

  # Register an element's tag/id/class in the index (no-op for non-elements).
  defp index_element(index, node_id, %NodeData.Element{} = element) do
    Table.index_put(index, node_id, element)
  end

  defp index_element(_index, _node_id, _node_data), do: :ok

  # The content DocumentFragment handle of a template element (nil if unset).
  defp element_content_impl(id, _from, state) do
    [{^id, %NodeData.Element{content: content_id}}] = :ets.lookup(state.nodes, id)
    reply = if content_id, do: node_handle(state.nodes, content_id), else: nil
    {:reply, reply, state}
  end

  # Generic ETS primitives. A caller module (DOM.Node/DOM.Element) builds a match
  # spec with `defmatchspecp`/`fun2msfun` and drives the nodes table directly
  # through these, instead of each row-local read/write needing its own bridge.
  def _select(server, match_spec) do
    GenServer.call(server, {:select, match_spec})
  end

  defp select_impl(match_spec, _from, state) do
    {:reply, :ets.select(state.nodes, match_spec), state}
  end

  def _select_replace(server, match_spec) do
    GenServer.call(server, {:select_replace, match_spec})
  end

  defp select_replace_impl(match_spec, _from, state) do
    {:reply, :ets.select_replace(state.nodes, match_spec), state}
  end

  # Runs a multi-step ETS operation `op.(nodes)` atomically inside the server (a
  # single message, so no other operation can interleave). Use this for any read-
  # modify-write against the table that can't be a single `_select`/
  # `_select_replace` hit; `op` returns the value to reply with.
  def _atomic_ets_op(server, op) do
    GenServer.call(server, {:atomic_ets_op, op})
  end

  defp atomic_ets_op_impl(op, _from, state) do
    {:reply, op.(state.nodes, state.index), state}
  end

  # ==========================================================================
  # Ranges
  # ==========================================================================

  @doc false
  # Create a range collapsed at (document, 0); monitor `owner` for cleanup. The
  # returned ref (the monitor ref) is the range's identity. Owner == this server
  # is illegal (a range must be owned by an external process).
  def _range_create(server, document_id, owner) do
    GenServer.call(server, {:range_create, document_id, owner})
  end

  defp range_create_impl(document_id, owner, _from, state) do
    if owner == self() do
      raise ArgumentError, "a range may not be owned by the document server process"
    end

    ref = Process.monitor(owner)
    key = Table.fetch!(state.nodes, document_id).start
    Table.range_put(state.index, ref, {key, 0}, {key, 0})
    {:reply, ref, state}
  end

  @doc false
  def _range_detach(server, range_id) do
    GenServer.call(server, {:range_detach, range_id})
  end

  defp range_detach_impl(range_id, _from, state) do
    Process.demonitor(range_id, [:flush])
    Table.range_delete(state.index, range_id)
    {:reply, :ok, state}
  end

  # An owner process died: drop all of its ranges (the :DOWN ref IS the range id).
  defp range_cleanup_impl(range_id, state) do
    Table.range_delete(state.index, range_id)
    {:noreply, state}
  end

  @doc false
  def _text_split(server, node_id, offset) do
    case GenServer.call(server, {:text_split, node_id, offset}) do
      {:ok, new_node} -> new_node
      {:error, :index_size} -> raise DOM.IndexSizeError
    end
  end

  # splitText (§): the original keeps chars 0..offset, a new Text sibling gets the
  # remainder. Boundaries in the original past `offset` move into the new node.
  defp text_split_impl(node_id, offset, _from, state) do
    value = Table.value(state.nodes, node_id)

    if offset > String.length(value) do
      {:reply, {:error, :index_size}, state}
    else
      {before, rest} = String.split_at(value, offset)
      orig_key = Table.fetch!(state.nodes, node_id).start
      parent_id = Table.parent(state.nodes, node_id)

      snapshot = range_snapshot(state)
      Table.set_value(state.nodes, node_id, before)
      new_id = Table.create_text(state.nodes, rest)
      insert_after(state.nodes, parent_id, new_id, node_id)
      resync_spans(state)

      new_key = Table.fetch!(state.nodes, new_id).start
      adjust_split_ranges(state, snapshot, parent_id, node_id, orig_key, new_key, offset)

      {:reply, {:ok, node_handle(state.nodes, new_id)}, state}
    end
  end

  @doc false
  def _range_clone_contents(server, range_id) do
    GenServer.call(server, {:range_clone_contents, range_id})
  end

  defp range_clone_contents_impl(range_id, _from, state) do
    {sc, so, ec, eo} = range_endpoints!(state.nodes, state.index, range_id)
    clones = DOM.Range.Contents.clone(state.nodes, sc, so, ec, eo)

    fragment_id = make_ref()
    Table.put(state.nodes, fragment_id, %NodeData.DocumentFragment{})
    Table.append_children(state.nodes, fragment_id, clones)
    Table.reindex(state.nodes, state.index)
    resync_spans(state)

    {:reply, node_handle(state.nodes, fragment_id), state}
  end

  @doc false
  def _range_extract_contents(server, range_id) do
    GenServer.call(server, {:range_extract_contents, range_id})
  end

  defp range_extract_contents_impl(range_id, _from, state) do
    {sc, so, ec, eo} = range_endpoints!(state.nodes, state.index, range_id)
    snapshot = range_snapshot(state)
    extracted = DOM.Range.Contents.extract(state.nodes, sc, so, ec, eo)

    fragment_id = make_ref()
    Table.put(state.nodes, fragment_id, %NodeData.DocumentFragment{})
    Table.append_children(state.nodes, fragment_id, extracted)
    Table.reindex(state.nodes, state.index)
    resync_spans(state)

    collapse_range_to_start(state, range_id)
    reconcile_ranges(state, snapshot)

    {:reply, node_handle(state.nodes, fragment_id), state}
  end

  @doc false
  def _range_delete_contents(server, range_id) do
    GenServer.call(server, {:range_delete_contents, range_id})
  end

  defp range_delete_contents_impl(range_id, _from, state) do
    {sc, so, ec, eo} = range_endpoints!(state.nodes, state.index, range_id)
    snapshot = range_snapshot(state)
    extracted = DOM.Range.Contents.extract(state.nodes, sc, so, ec, eo)

    Enum.each(extracted, &delete_subtree(state.nodes, state.index, &1))
    resync_spans(state)

    collapse_range_to_start(state, range_id)
    reconcile_ranges(state, snapshot)

    {:reply, :ok, state}
  end

  @doc false
  def _range_insert_node(server, range_id, node_id) do
    GenServer.call(server, {:range_insert_node, range_id, node_id})
  end

  defp range_insert_node_impl(range_id, node_id, _from, state) do
    {{start_key, so}, _stop} = Table.range_boundaries(state.index, range_id)
    container = Table.node_at_start_key(state.nodes, start_key)
    do_insert_at_boundary(state, container, so, node_id)
    {:reply, :ok, state}
  end

  # Insert node_id at boundary (container, offset). Text container: split at offset
  # (unless at an edge) and insert before the tail. Element/fragment: insert at the
  # child index `offset`.
  defp do_insert_at_boundary(state, container, offset, node_id) do
    if Table.type(state.nodes, container) in [:text, :comment] do
      insert_into_text(state, container, offset, node_id)
    else
      insert_at_child_index(state, container, offset, node_id)
    end
  end

  defp insert_into_text(state, text_id, offset, node_id) do
    parent_id = Table.parent(state.nodes, text_id)

    reference =
      cond do
        offset == 0 -> text_id
        offset >= String.length(Table.value(state.nodes, text_id)) -> nil
        :else -> split_text_for_insert(state, text_id, offset)
      end

    insert_relative(state, parent_id, node_id, reference)
  end

  # Split `text_id` at `offset`; return the tail node to insert before.
  defp split_text_for_insert(state, text_id, offset) do
    {before, rest} = String.split_at(Table.value(state.nodes, text_id), offset)
    Table.set_value(state.nodes, text_id, before)
    tail = Table.create_text(state.nodes, rest)
    insert_after(state.nodes, Table.parent(state.nodes, text_id), tail, text_id)
    tail
  end

  defp insert_at_child_index(state, container, offset, node_id) do
    reference = Enum.at(Table.children(state.nodes, container), offset)
    insert_relative(state, container, node_id, reference)
  end

  # Insert node_id under parent before `reference` (append when nil), routing
  # through the server impls so hierarchy + range adjustment run.
  defp insert_relative(state, parent_id, node_id, reference) do
    if reference do
      insert_before_impl(parent_id, node_id, reference, nil, state)
    else
      append_child_impl(parent_id, node_id, nil, state)
    end
  end

  @doc false
  def _range_surround_contents(server, range_id, element_id) do
    case GenServer.call(server, {:range_surround_contents, range_id, element_id}) do
      :ok -> :ok
      {:error, :invalid_state} -> raise DOM.InvalidStateError
    end
  end

  defp range_surround_contents_impl(range_id, element_id, _from, state) do
    {sc, _so, ec, _eo} = range_endpoints!(state.nodes, state.index, range_id)

    if partially_selects_non_text?(state.nodes, sc, ec) do
      {:reply, {:error, :invalid_state}, state}
    else
      # extract -> append into element -> insert element at the range start
      {:reply, fragment, _state} = range_extract_contents_impl(range_id, nil, state)

      Enum.each(
        Table.children(state.nodes, fragment.node_id),
        &Table.append_child(state.nodes, element_id, &1)
      )

      Table.reindex(state.nodes, state.index)
      resync_spans(state)

      {{start_key, so2}, _} = Table.range_boundaries(state.index, range_id)
      container = Table.node_at_start_key(state.nodes, start_key)
      do_insert_at_boundary(state, container, so2, element_id)

      # select the inserted element
      select_element_in_range(state, range_id, element_id)
      {:reply, :ok, state}
    end
  end

  # A range partially selects a non-Text node when any PARTIALLY-CONTAINED node is
  # not character data. A node is partially contained when it contains one boundary
  # endpoint but not the other — i.e. the nodes on each boundary's path from the
  # container up to (excluding) the common ancestor. surroundContents forbids this.
  defp partially_selects_non_text?(nodes, sc, ec) do
    common = range_common_ancestor(nodes, sc, ec)

    (partially_contained_chain(nodes, sc, common) ++ partially_contained_chain(nodes, ec, common))
    |> Enum.any?(&(Table.type(nodes, &1) not in [:text, :comment]))
  end

  # The nodes from `boundary` up to (but not including) `common`.
  defp partially_contained_chain(_nodes, common, common), do: []

  defp partially_contained_chain(nodes, node, common) do
    case Table.parent(nodes, node) do
      ^common -> [node]
      nil -> [node]
      parent -> [node | partially_contained_chain(nodes, parent, common)]
    end
  end

  defp range_common_ancestor(nodes, a, b) do
    a_chain = ancestor_or_self_chain(nodes, a)
    b_set = MapSet.new(ancestor_or_self_chain(nodes, b))
    Enum.find(a_chain, &MapSet.member?(b_set, &1))
  end

  defp ancestor_or_self_chain(nodes, id) do
    case Table.parent(nodes, id) do
      nil -> [id]
      parent -> [id | ancestor_or_self_chain(nodes, parent)]
    end
  end

  # After surround, set the range to select `element_id` (start before, end after).
  defp select_element_in_range(state, range_id, element_id) do
    parent_id = Table.parent(state.nodes, element_id)
    at = child_index(state.nodes, parent_id, element_id)
    pkey = Table.fetch!(state.nodes, parent_id).start
    Table.range_put(state.index, range_id, {pkey, at}, {pkey, at + 1})
  end

  # Collapse `range_id` onto its start boundary (after extract/delete, per spec).
  defp collapse_range_to_start(state, range_id) do
    {{start_key, so}, _stop} = Table.range_boundaries(state.index, range_id)
    Table.range_put(state.index, range_id, {start_key, so}, {start_key, so})
  end

  # After an extract/delete that moved/removed nodes, re-pin every OTHER range's
  # boundaries whose container key changed (the generic remap), and drop boundaries
  # whose container no longer exists onto a still-live ancestor position. The
  # remap catches key changes; dangling boundaries are cleaned by re-resolving.
  defp reconcile_ranges(state, snapshot), do: apply_remap(state, snapshot)

  # Resolve a range's stored boundaries into `{start_container_id, start_offset,
  # end_container_id, end_offset}` via the extent-key reverse lookup.
  defp range_endpoints!(nodes, index, range_id) do
    {{start_key, so}, {stop_key, eo}} = Table.range_boundaries(index, range_id)
    {Table.node_at_start_key(nodes, start_key), so, Table.node_at_start_key(nodes, stop_key), eo}
  end

  # Insert `new_id` immediately after `ref_id` under `parent_id` (append if last).
  defp insert_after(nodes, parent_id, new_id, ref_id) do
    kids = Table.children(nodes, parent_id)
    at = Enum.find_index(kids, &(&1 == ref_id))

    case Enum.at(kids, at + 1) do
      nil -> Table.append_child(nodes, parent_id, new_id)
      next -> Table.insert_before(nodes, parent_id, new_id, next)
    end
  end

  # split rule (boundaries past the split move into the new node) + the insert of
  # the new sibling (a child was added after the original's index in the parent).
  defp adjust_split_ranges(_state, nil, _parent, _orig, _ok, _nk, _off), do: :ok

  defp adjust_split_ranges(state, snapshot, parent_id, orig_id, orig_key, new_key, offset) do
    DOM.Range.Adjust.on_split(state.nodes, state.index, orig_key, new_key, offset)
    at = child_index(state.nodes, parent_id, orig_id)
    parent_key = Map.get(snapshot, parent_id) || current_start(state.nodes, parent_id)
    DOM.Range.Adjust.on_insert(state.nodes, state.index, parent_key, at, 1)
    :ok
  end

  @doc """
  Assert the document's ETS invariants (see `DOM.NodeData.Table.check_consistency!/1`),
  raising on violation. Test-only; wired into an `on_exit` hook by `DOM.Case`.
  """
  @spec _check_index_consistency!(GenServer.server()) :: :ok
  def _check_index_consistency!(server) do
    GenServer.call(server, :check_index_consistency)
  end

  defp check_index_consistency_impl(_from, state) do
    {:reply, Table.check_consistency!(state.nodes, state.index), state}
  end

  def _node_append_child(server, parent_id, %{server: child_server, node_id: child_id} = child) do
    result =
      if child_server == server do
        GenServer.call(server, {:append_child, parent_id, child_id})
      else
        subtree = _export_subtree(child_server, child_id)
        result = GenServer.call(server, {:append_subtree, parent_id, child_id, subtree})

        if match?({:ok, _transferred_child}, result) do
          _remove_subtree(child_server, child_id)
        end

        result
      end

    case result do
      :ok -> child
      {:ok, transferred_child} -> transferred_child
      {:error, :hierarchy_request} -> raise DOM.HierarchyRequestError
    end
  end

  defp append_child_impl(parent_id, child_id, _from, state) do
    child_data = fetch_node!(state.nodes, child_id)
    parent_data = fetch_node!(state.nodes, parent_id)

    cond do
      invalid_hierarchy?(state.nodes, parent_data, parent_id, child_data, child_id, nil, nil) ->
        {:reply, {:error, :hierarchy_request}, state}

      match?(%NodeData.DocumentFragment{}, child_data) ->
        append_fragment(state.nodes, parent_id, child_id, child_data)
        resync_spans(state)
        {:reply, :ok, state}

      :else ->
        snapshot = range_snapshot(state)
        at = length(Table.children(state.nodes, parent_id))
        Table.append_child(state.nodes, parent_id, child_id)
        resync_spans(state)
        adjust_ranges(state, snapshot, {:insert, parent_id, at, 1})
        {:reply, :ok, state}
    end
  end

  # Mirror the record extents (written live by the extent-authoritative mutators)
  # into the index's span rows after an incremental mutation. Idempotent; the
  # extents are the order source, so this only copies them — no carve from the
  # `children` field.
  defp resync_spans(state), do: Table.span_index_all(state.nodes, state.index)

  # A snapshot of every node's start key, captured BEFORE a structural mutation so
  # live-range adjustment can (a) remap boundaries whose container's key changed
  # (graft) and (b) find a parent/removed container by its pre-mutation key.
  defp range_snapshot(state) do
    if Table.range_all_rows(state.index) == [] do
      nil
    else
      for {id, %{start: start}} when start != nil <- :ets.tab2list(state.nodes),
          into: %{},
          do: {id, start}
    end
  end

  # Apply live-range adjustment after a structural op, given the pre-mutation
  # `snapshot` (nil when no ranges exist — a fast no-op). `op` describes the edit:
  #   {:insert, parent_id, at_index, count} | {:remove, parent_id, at_index, removed_id}
  # The remap (containers whose start key changed) always runs; then the op's
  # child-index offset rule.
  defp adjust_ranges(_state, nil, _op), do: :ok

  defp adjust_ranges(state, snapshot, op) do
    apply_remap(state, snapshot)
    apply_offset_rule(state, snapshot, op)
    :ok
  end

  # Remap boundaries whose container node's start key changed between the snapshot
  # and now (a graft moved the container / its subtree).
  defp apply_remap(state, snapshot) do
    remap =
      for {id, old_key} <- snapshot,
          new = current_start(state.nodes, id),
          new != nil and new != old_key,
          into: %{},
          do: {old_key, new}

    if remap != %{}, do: DOM.Range.Adjust.on_remap(state.nodes, state.index, remap)
  end

  defp current_start(nodes, id) do
    case :ets.lookup(nodes, id) do
      [{^id, %{start: start}}] -> start
      _ -> nil
    end
  end

  defp apply_offset_rule(state, snapshot, {:insert, parent_id, at, count}) do
    parent_key = Map.get(snapshot, parent_id) || current_start(state.nodes, parent_id)
    DOM.Range.Adjust.on_insert(state.nodes, state.index, parent_key, at, count)
  end

  defp apply_offset_rule(state, snapshot, {:remove, parent_id, at, removed_keys}) do
    parent_key = Map.get(snapshot, parent_id) || current_start(state.nodes, parent_id)
    DOM.Range.Adjust.on_remove(state.nodes, state.index, parent_key, at, removed_keys)
  end

  # Flatten a fragment's children onto `parent_id` (append), placing all of them in
  # one multispan-carved gap (snapshot the ordered children first — the bulk move
  # re-parents them, emptying the fragment).
  defp append_fragment(nodes, parent_id, fragment_id, _fragment) do
    Table.append_children(nodes, parent_id, Table.children(nodes, fragment_id))
  end

  # Flatten a fragment's children into `parent_id` before `reference_child_id`, in
  # order, in one multispan-carved gap.
  defp insert_fragment(nodes, parent_id, fragment_id, _fragment, reference_child_id) do
    Table.insert_children_before(
      nodes,
      parent_id,
      Table.children(nodes, fragment_id),
      reference_child_id
    )
  end

  def _node_insert_before(server, parent_id, child, nil) do
    _node_append_child(server, parent_id, child)
  end

  def _node_insert_before(
        server,
        parent_id,
        %{server: child_server, node_id: child_id} = child,
        %{node_id: reference_child_id}
      ) do
    result =
      if child_server == server do
        GenServer.call(server, {:insert_before, parent_id, child_id, reference_child_id})
      else
        subtree = _export_subtree(child_server, child_id)

        result =
          GenServer.call(
            server,
            {:insert_subtree, parent_id, child_id, reference_child_id, subtree}
          )

        if match?({:ok, _transferred_child}, result) do
          _remove_subtree(child_server, child_id)
        end

        result
      end

    case result do
      :ok -> child
      {:ok, transferred_child} -> transferred_child
      {:error, :hierarchy_request} -> raise DOM.HierarchyRequestError
      {:error, :not_found} -> raise DOM.NotFoundError
    end
  end

  defp insert_before_impl(parent_id, child_id, reference_child_id, _from, state) do
    child_data = fetch_node!(state.nodes, child_id)
    parent_data = fetch_node!(state.nodes, parent_id)

    cond do
      inclusive_ancestor?(state.nodes, child_id, parent_id) ->
        {:reply, {:error, :hierarchy_request}, state}

      reference_child_id not in Table.children(state.nodes, parent_id) ->
        {:reply, {:error, :not_found}, state}

      invalid_hierarchy?(
        state.nodes,
        parent_data,
        parent_id,
        child_data,
        child_id,
        reference_child_id,
        nil
      ) ->
        {:reply, {:error, :hierarchy_request}, state}

      child_id == reference_child_id ->
        {:reply, :ok, state}

      match?(%NodeData.DocumentFragment{}, child_data) ->
        insert_fragment(state.nodes, parent_id, child_id, child_data, reference_child_id)
        resync_spans(state)
        {:reply, :ok, state}

      :else ->
        snapshot = range_snapshot(state)
        at = child_index(state.nodes, parent_id, reference_child_id)
        Table.insert_before(state.nodes, parent_id, child_id, reference_child_id)
        resync_spans(state)
        adjust_ranges(state, snapshot, {:insert, parent_id, at, 1})
        {:reply, :ok, state}
    end
  end

  defp append_subtree_impl(parent_id, child_id, subtree, _from, state) do
    subtree_nodes = Map.new(subtree)
    child_data = Map.fetch!(subtree_nodes, child_id)
    parent_data = fetch_node!(state.nodes, parent_id)

    if invalid_hierarchy?(
         state.nodes,
         parent_data,
         parent_id,
         child_data,
         child_id,
         nil,
         subtree_nodes
       ) do
      {:reply, {:error, :hierarchy_request}, state}
    else
      materialize_subtree(state.nodes, state.index, child_id, subtree)

      if match?(%NodeData.DocumentFragment{}, child_data) do
        append_fragment(state.nodes, parent_id, child_id, child_data)
      else
        Table.append_child(state.nodes, parent_id, child_id)
      end

      resync_spans(state)
      {:reply, {:ok, node_handle(state.nodes, child_id)}, state}
    end
  end

  defp insert_subtree_impl(parent_id, child_id, reference_child_id, subtree, _from, state) do
    subtree_nodes = Map.new(subtree)
    child_data = Map.fetch!(subtree_nodes, child_id)
    parent_data = fetch_node!(state.nodes, parent_id)

    cond do
      reference_child_id not in Table.children(state.nodes, parent_id) ->
        {:reply, {:error, :not_found}, state}

      invalid_hierarchy?(
        state.nodes,
        parent_data,
        parent_id,
        child_data,
        child_id,
        reference_child_id,
        subtree_nodes
      ) ->
        {:reply, {:error, :hierarchy_request}, state}

      :else ->
        materialize_subtree(state.nodes, state.index, child_id, subtree)

        if match?(%NodeData.DocumentFragment{}, child_data) do
          insert_fragment(state.nodes, parent_id, child_id, child_data, reference_child_id)
        else
          Table.insert_before(state.nodes, parent_id, child_id, reference_child_id)
        end

        resync_spans(state)
        {:reply, {:ok, node_handle(state.nodes, child_id)}, state}
    end
  end

  defp materialize_subtree(nodes, index, child_id, subtree) do
    subtree =
      Enum.map(subtree, fn
        {^child_id, node_data} -> {child_id, %{node_data | parent: nil}}
        entry -> entry
      end)

    true = :ets.insert(nodes, subtree)
    Enum.each(subtree, fn {id, node_data} -> index_element(index, id, node_data) end)
  end

  def _node_remove_child(server, parent_id, %{node_id: child_id} = child) do
    case GenServer.call(server, {:remove_child, parent_id, child_id}) do
      :ok -> child
      {:error, :not_found} -> raise DOM.NotFoundError
    end
  end

  defp remove_child_impl(parent_id, child_id, _from, state) do
    if child_id in Table.children(state.nodes, parent_id) do
      snapshot = range_snapshot(state)
      at = child_index(state.nodes, parent_id, child_id)
      removed_keys = removed_subtree_keys(state.nodes, child_id)
      Table.remove_child(state.nodes, parent_id, child_id)
      resync_spans(state)
      adjust_ranges(state, snapshot, {:remove, parent_id, at, removed_keys})
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  # The index of `child_id` among `parent_id`'s children (document order).
  defp child_index(nodes, parent_id, child_id) do
    nodes |> Table.children(parent_id) |> Enum.find_index(&(&1 == child_id))
  end

  # The set of start keys of `id` and its descendants (a removed subtree's keys),
  # for relocating boundaries that were inside it.
  defp removed_subtree_keys(nodes, id) do
    [id | Table.descendant_ids(nodes, id)]
    |> Enum.map(&current_start(nodes, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  def _node_replace_child(
        server,
        parent_id,
        %{server: new_server, node_id: new_child_id},
        %{node_id: old_child_id} = old_child
      ) do
    result =
      if new_server == server do
        GenServer.call(server, {:replace_child, parent_id, new_child_id, old_child_id})
      else
        subtree = _export_subtree(new_server, new_child_id)

        result =
          GenServer.call(
            server,
            {:replace_subtree, parent_id, new_child_id, old_child_id, subtree}
          )

        if match?({:ok, _replaced}, result) do
          _remove_subtree(new_server, new_child_id)
        end

        result
      end

    case result do
      {:ok, _replaced} -> old_child
      {:error, :hierarchy_request} -> raise DOM.HierarchyRequestError
      {:error, :not_found} -> raise DOM.NotFoundError
    end
  end

  defp replace_child_impl(parent_id, new_child_id, old_child_id, _from, state) do
    new_child_data = fetch_node!(state.nodes, new_child_id)
    parent_data = fetch_node!(state.nodes, parent_id)

    replace_child_common(
      parent_id,
      parent_data,
      new_child_id,
      new_child_data,
      old_child_id,
      nil,
      fn -> detach_from_parent(state.nodes, new_child_id, new_child_data) end,
      state
    )
  end

  defp replace_subtree_impl(parent_id, new_child_id, old_child_id, subtree, _from, state) do
    subtree_nodes = Map.new(subtree)
    new_child_data = Map.fetch!(subtree_nodes, new_child_id)
    parent_data = fetch_node!(state.nodes, parent_id)

    replace_child_common(
      parent_id,
      parent_data,
      new_child_id,
      new_child_data,
      old_child_id,
      subtree_nodes,
      fn -> materialize_subtree(state.nodes, state.index, new_child_id, subtree) end,
      state
    )
  end

  # Shared replaceChild body. `prepare` either detaches a same-document new
  # child from its old parent or materializes a transferred subtree; the
  # document validity check excludes `old_child_id`, which is leaving.
  defp replace_child_common(
         parent_id,
         parent_data,
         new_child_id,
         new_child_data,
         old_child_id,
         subtree_nodes,
         prepare,
         state
       ) do
    cond do
      old_child_id not in Table.children(state.nodes, parent_id) ->
        {:reply, {:error, :not_found}, state}

      new_child_id == old_child_id ->
        {:reply, {:ok, node_handle(state.nodes, new_child_id)}, state}

      invalid_hierarchy?(
        state.nodes,
        parent_data,
        parent_id,
        new_child_data,
        old_child_id,
        old_child_id,
        subtree_nodes
      ) ->
        {:reply, {:error, :hierarchy_request}, state}

      :else ->
        prepare.()
        # Splice the replacement in immediately before old_child (each moved node
        # via the extent-authoritative insert_before, so extents land in old's
        # neighborhood), then remove old_child — leaving its gap.
        if match?(%NodeData.DocumentFragment{}, new_child_data) do
          insert_fragment(state.nodes, parent_id, new_child_id, new_child_data, old_child_id)
        else
          Table.insert_before(state.nodes, parent_id, new_child_id, old_child_id)
        end

        Table.remove_child(state.nodes, parent_id, old_child_id)
        resync_spans(state)
        {:reply, {:ok, node_handle(state.nodes, new_child_id)}, state}
    end
  end

  def _export_subtree(server, node_id) do
    GenServer.call(server, {:export_subtree, node_id})
  end

  defp export_subtree_impl(node_id, _from, state) do
    {:reply, subtree(state.nodes, node_id), state}
  end

  def _remove_subtree(server, node_id) do
    GenServer.call(server, {:remove_subtree, node_id})
  end

  defp remove_subtree_impl(node_id, _from, state) do
    node_data = fetch_node!(state.nodes, node_id)
    detach_from_parent(state.nodes, node_id, node_data)
    delete_subtree(state.nodes, state.index, node_id)
    resync_spans(state)
    {:reply, :ok, state}
  end

  defp invalid_hierarchy?(nodes, parent, parent_id, child, child_id, reference_child_id, subtree) do
    inclusive_ancestor?(nodes, child_id, parent_id) or
      (match?(%NodeData.Document{}, parent) and
         invalid_document_child?(nodes, parent_id, child, child_id, reference_child_id, subtree))
  end

  # `document_id` is the document (parent) being inserted into; its ordered children
  # come from the extent index (Table.children), not a record field.
  defp invalid_document_child?(
         nodes,
         document_id,
         %NodeData.Element{},
         child_id,
         reference_child_id,
         _sub
       ) do
    document_has_kind?(nodes, document_id, NodeData.Element, child_id) or
      doctype_at_or_after?(nodes, document_id, reference_child_id)
  end

  defp invalid_document_child?(
         nodes,
         document_id,
         %NodeData.DocumentType{},
         child_id,
         reference_id,
         _sub
       ) do
    document_has_kind?(nodes, document_id, NodeData.DocumentType, child_id) or
      element_before?(nodes, document_id, reference_id)
  end

  defp invalid_document_child?(
         nodes,
         document_id,
         %NodeData.DocumentFragment{},
         fragment_id,
         _reference_child_id,
         subtree
       ) do
    invalid_document_fragment?(nodes, document_id, fragment_id, subtree)
  end

  defp invalid_document_child?(_nodes, _document_id, _child, _child_id, _reference_child_id, _sub) do
    false
  end

  # An element precedes the insertion point: with a nil reference (append), any
  # element counts; otherwise only elements before the reference child.
  defp element_before?(nodes, document_id, reference_child_id) do
    nodes
    |> Table.children(document_id)
    |> Enum.take_while(&(&1 != reference_child_id))
    |> Enum.any?(&match?(%NodeData.Element{}, fetch_node!(nodes, &1)))
  end

  # A doctype sits at or after the insertion point: with a nil reference
  # (append), any doctype counts; otherwise doctypes from the reference child on.
  defp doctype_at_or_after?(nodes, document_id, reference_child_id) do
    nodes
    |> Table.children(document_id)
    |> Enum.drop_while(&(&1 != reference_child_id))
    |> Enum.any?(&match?(%NodeData.DocumentType{}, fetch_node!(nodes, &1)))
  end

  defp invalid_document_fragment?(nodes, document_id, fragment_id, subtree_nodes) do
    kinds =
      Enum.map(fragment_children(nodes, fragment_id, subtree_nodes), fn child_id ->
        node_kind(nodes, child_id, subtree_nodes)
      end)

    element_count = Enum.count(kinds, &(&1 == NodeData.Element))

    NodeData.Text in kinds or
      element_count > 1 or
      (element_count == 1 and document_has_kind?(nodes, document_id, NodeData.Element, nil))
  end

  # A fragment's children: from the live extents (same-doc), else from the
  # transported subtree map — derived by parent pointer + extent order, since the
  # records carry `parent`/`start`, not a `children` field.
  defp fragment_children(nodes, fragment_id, nil), do: Table.children(nodes, fragment_id)

  defp fragment_children(_nodes, fragment_id, subtree_nodes) do
    subtree_nodes
    |> Enum.filter(fn {_id, data} -> data.parent == fragment_id end)
    |> Enum.sort_by(fn {_id, data} -> data.start end)
    |> Enum.map(fn {id, _data} -> id end)
  end

  # The NodeData struct MODULE of a node (used as a kind discriminator).
  defp node_kind(nodes, node_id, nil), do: fetch_node!(nodes, node_id).__struct__

  defp node_kind(_nodes, node_id, subtree_nodes),
    do: Map.fetch!(subtree_nodes, node_id).__struct__

  defp document_has_kind?(nodes, document_id, kind, except_id) do
    nodes
    |> Table.children(document_id)
    |> Enum.any?(fn node_id ->
      node_id != except_id and fetch_node!(nodes, node_id).__struct__ == kind
    end)
  end

  defp detach_from_parent(nodes, child_id, _child) do
    Table.detach(nodes, child_id)
  end

  defp inclusive_ancestor?(nodes, ancestor_id, node_id) do
    cond do
      ancestor_id == node_id ->
        true

      parent_id = fetch_node!(nodes, node_id).parent ->
        inclusive_ancestor?(nodes, ancestor_id, parent_id)

      :else ->
        false
    end
  end

  def _node_owner_document(server, node_id) do
    GenServer.call(server, {:owner_document, node_id})
  end

  defp owner_document_impl(node_id, _from, state) do
    owner =
      if node_id != state.document_id do
        %Node{server: self(), node_id: state.document_id, type: :document}
      end

    {:reply, owner, state}
  end

  def _node_clone_node(server, node_id, deep?) do
    GenServer.call(server, {:clone_node, node_id, deep?})
  end

  defp clone_node_impl(node_id, deep?, _from, state) do
    clone_id = Table.clone(state.nodes, node_id, deep?)
    Table.reindex(state.nodes, state.index)
    Table.span_index_all(state.nodes, state.index)
    {:reply, node_handle(state.nodes, clone_id), state}
  end

  def _element_inner_html(server, node_id) do
    GenServer.call(server, {:inner_html, node_id})
  end

  defp inner_html_impl(node_id, _from, state) do
    element = fetch_node!(state.nodes, node_id)
    child_ids = Table.children_by_extent(state.nodes, node_id)
    iodata = DOM.HTML.children(element.local_name, child_ids, state.nodes)
    {:reply, IO.iodata_to_binary(iodata), state}
  end

  @doc false
  def _element_set_inner_html(server, node_id, html) do
    GenServer.call(server, {:set_inner_html, node_id, html})
  end

  # innerHTML setter (§): fragment-parse `html` with this element as the context,
  # then replace the element's children with the parsed fragment's children. All
  # in-process on this server's table via DOM.NodeData.Table.
  defp set_inner_html_impl(node_id, html, _from, state) do
    element = Table.fetch!(state.nodes, node_id)
    context = %{name: element.local_name, namespace: element.namespace}
    root = fragment_root_for(html, context, state)

    Enum.each(Table.children(state.nodes, node_id), &Table.remove_child(state.nodes, node_id, &1))
    Table.append_children(state.nodes, node_id, Table.children(state.nodes, root))

    resync_spans(state)
    {:reply, :ok, state}
  end

  @doc false
  def _element_set_outer_html(server, node_id, html) do
    case GenServer.call(server, {:set_outer_html, node_id, html}) do
      :ok -> :ok
      {:error, :no_modification} -> raise DOM.NoModificationAllowedError
    end
  end

  # outerHTML setter (§): fragment-parse `html` in the element's PARENT context,
  # then replace the element itself (in the parent) with the parsed nodes. An
  # element with no element parent cannot be replaced.
  defp set_outer_html_impl(node_id, html, _from, state) do
    parent_id = Table.parent(state.nodes, node_id)

    if is_nil(parent_id) or Table.type(state.nodes, parent_id) != :element do
      {:reply, {:error, :no_modification}, state}
    else
      parent = Table.fetch!(state.nodes, parent_id)
      context = %{name: parent.local_name, namespace: parent.namespace}
      root = fragment_root_for(html, context, state)

      Table.insert_children_before(
        state.nodes,
        parent_id,
        Table.children(state.nodes, root),
        node_id
      )

      Table.remove_child(state.nodes, parent_id, node_id)
      resync_spans(state)
      {:reply, :ok, state}
    end
  end

  # Fragment-parse `html` in `context` into this document's table; return the
  # synthetic fragment-root id (whose children are the parsed nodes). build_into's
  # bulk-load indexes the parsed elements; span_index_all mirrors the fresh extents
  # into the span rows.
  defp fragment_root_for(html, context, state) do
    tokens = DOM.HTML.fragment_tokens(html, context.name)

    root =
      TreeBuilder.build_fragment_into(
        state.nodes,
        state.index,
        state.document_id,
        tokens,
        context
      )

    Table.span_index_all(state.nodes, state.index)
    root
  end

  def _element_outer_html(server, node_id) do
    GenServer.call(server, {:outer_html, node_id})
  end

  defp outer_html_impl(node_id, _from, state) do
    iodata = DOM.HTML.serialize(fetch_node!(state.nodes, node_id), node_id, state.nodes)
    {:reply, IO.iodata_to_binary(iodata), state}
  end

  defp get_elements_by_tag_name_impl(node_id, name, _from, state) do
    descendants = descendant_ids(state.nodes, node_id)

    ids =
      if name == "*" do
        # "*" wants every element descendant — the tag index gives no benefit, so
        # keep the element scan.
        Enum.filter(descendants, &element?(state.nodes, &1))
      else
        # A named tag is a point lookup in the tag index; keep tree order by
        # filtering the ordered descendant walk against the (scope-free) match set.
        matched = MapSet.new(Table.index_lookup(state.index, :tag, name))
        Enum.filter(descendants, &MapSet.member?(matched, &1))
      end

    {:reply, Enum.map(ids, &node_handle(state.nodes, &1)), state}
  end

  defp element?(nodes, node_id), do: match?(%NodeData.Element{}, fetch_node!(nodes, node_id))

  defp get_element_by_id_impl(root_id, id, _from, state) do
    # The index gives every node with this id doc-wide (unordered); intersect with
    # the scope root's descendants and return the first in tree order.
    matches = MapSet.new(Table.index_lookup(state.index, :id, id))

    match_id =
      if MapSet.size(matches) == 0 do
        nil
      else
        Enum.find(descendant_ids(state.nodes, root_id), &MapSet.member?(matches, &1))
      end

    match = if match_id, do: node_handle(state.nodes, match_id)
    {:reply, match, state}
  end

  defp get_elements_by_class_name_impl(root_id, names, _from, state) do
    wanted = class_tokens(names)

    matches =
      if wanted == [] do
        []
      else
        # Each token's index lookup yields all nodes carrying it doc-wide;
        # intersect those sets (an element must carry EVERY token), then filter to
        # the scope root's descendants in tree order.
        matched =
          wanted
          |> Enum.map(&MapSet.new(Table.index_lookup(state.index, :class, &1)))
          |> Enum.reduce(&MapSet.intersection/2)

        state.nodes
        |> descendant_ids(root_id)
        |> Enum.filter(&MapSet.member?(matched, &1))
        |> Enum.map(&node_handle(state.nodes, &1))
      end

    {:reply, matches, state}
  end

  defp query_selector_all_impl(root_id, selector, _from, state) do
    ids = query_ids(root_id, selector, state)
    {:reply, Enum.map(ids, &node_handle(state.nodes, &1)), state}
  end

  defp query_selector_impl(root_id, selector, _from, state) do
    match =
      case query_ids(root_id, selector, state) do
        [id | _] -> node_handle(state.nodes, id)
        [] -> nil
      end

    {:reply, match, state}
  end

  # `selector` arrives already parsed and validated by the caller (parse_selector!).
  # In a `matches` context the node itself is the scoping root for `:scope`.
  defp matches_impl(node_id, selector, _from, state) do
    scoped = DOM.CSS.bind_scope(selector, node_id)
    context = css_context(state)

    matched =
      Enum.any?(scoped, fn complex -> DOM.CSS.match(complex, context, [node_id]) != [] end)

    {:reply, matched, state}
  end

  # The tables a CSS match runs against (see DOM.CSS.context/0).
  defp css_context(state), do: %{nodes: state.nodes, index: state.index}

  # Descendant element ids of `root_id` matching `selector`, in tree order. Each
  # complex in the selector list contributes its matches; the union is ordered by
  # the tree-order descendant walk.
  # `selector` arrives already parsed and validated by the caller (parse_selector!).
  # `:scope` is bound to `root_id` so it can anchor relative matches (`:scope > p`)
  # via the combinator chain. Per querySelectorAll, the candidate result set is
  # the root's descendants only — the root itself is never returned, so a bare
  # `:scope` matches nothing (mirrors the browser).
  defp query_ids(root_id, selector, state) do
    scoped = DOM.CSS.bind_scope(selector, root_id)
    candidates = descendant_ids(state.nodes, root_id)
    context = css_context(state)

    matched =
      scoped
      |> Enum.flat_map(fn complex -> DOM.CSS.match(complex, context, candidates) end)
      |> MapSet.new()

    Enum.filter(candidates, &MapSet.member?(matched, &1))
  end

  defp class_tokens(names), do: String.split(names)

  def _node_text_content(server, node_id) do
    GenServer.call(server, {:text_content, node_id})
  end

  defp text_content_impl(node_id, _from, state) do
    text =
      state.nodes
      |> descendants(node_id)
      |> Enum.filter(&match?(%NodeData.Text{}, &1))
      |> Enum.map_join("", & &1.value)

    {:reply, text, state}
  end

  def _node_set_text_content(server, node_id, value) do
    GenServer.call(server, {:set_text_content, node_id, value})
  end

  # Replace all children with a single Text node (none when value is empty).
  defp set_text_content_impl(node_id, value, _from, state) do
    state.nodes
    |> Table.children(node_id)
    |> Enum.each(&delete_subtree(state.nodes, state.index, &1))

    if value != "" do
      # append via the extent-authoritative mutator so the new text node is placed
      # (extent written), then mirrored into the span rows by resync.
      text_id = Table.create_text(state.nodes, value)
      Table.append_child(state.nodes, node_id, text_id)
    end

    resync_spans(state)
    {:reply, :ok, state}
  end

  # Delete a subtree from the node table and retract each node's index + span rows.
  defp delete_subtree(nodes, index, node_id) do
    nodes
    |> subtree(node_id)
    |> Enum.each(fn {id, _node_data} ->
      Table.index_retract(index, id)
      Table.span_retract(index, id)
      :ets.delete(nodes, id)
    end)
  end

  def _node_set_value(server, node_id, value) do
    GenServer.call(server, {:set_value, node_id, value})
  end

  defp set_value_impl(node_id, value, _from, state) do
    node = fetch_node!(state.nodes, node_id)
    put_node(state.nodes, node_id, %{node | value: value})
    {:reply, :ok, state}
  end

  # Descendant node_data in tree order, excluding the node itself.
  defp descendants(nodes, node_id) do
    nodes
    |> descendant_entries(node_id)
    |> Enum.map(fn {_id, node_data} -> node_data end)
  end

  # Descendant node ids in tree order, excluding the node itself.
  defp descendant_ids(nodes, node_id) do
    nodes
    |> descendant_entries(node_id)
    |> Enum.map(fn {id, _node_data} -> id end)
  end

  defp descendant_entries(nodes, node_id) do
    nodes
    |> Table.children(node_id)
    |> Enum.flat_map(&subtree(nodes, &1))
  end

  # ==========================================================================
  # Helper functions
  # ==========================================================================

  defp fetch_node!(nodes, node_id), do: Table.fetch!(nodes, node_id)

  defp put_node(nodes, node_id, node), do: Table.put(nodes, node_id, node)

  defp node_handle(nodes, node_id) do
    type = nodes |> fetch_node!(node_id) |> NodeData.type()
    %Node{server: self(), node_id: node_id, type: type}
  end

  defp subtree(nodes, node_id) do
    node_data = fetch_node!(nodes, node_id)

    [{node_id, node_data}] ++
      Enum.flat_map(Table.children(nodes, node_id), &subtree(nodes, &1))
  end

  # ==========================================================================
  # Router
  # ==========================================================================

  @impl true
  def handle_continue({:parse, tokens}, state) do
    parse_impl(tokens, state)
  end

  def handle_continue({:fragment, {tokens, context}}, state) do
    fragment_impl(tokens, context, state)
  end

  # An owner process monitored for a range died — the monitor ref is the range id.
  @impl true
  def handle_info({:DOWN, range_id, :process, _pid, _reason}, state) do
    range_cleanup_impl(range_id, state)
  end

  @impl true
  def handle_call(:fragment_root, from, state) do
    fragment_root_impl(from, state)
  end

  def handle_call({:create, node_data}, from, state) do
    create_impl(node_data, from, state)
  end

  @impl true
  def handle_call({:element_content, id}, from, state) do
    element_content_impl(id, from, state)
  end

  @impl true
  def handle_call({:select, match_spec}, from, state) do
    select_impl(match_spec, from, state)
  end

  @impl true
  def handle_call({:select_replace, match_spec}, from, state) do
    select_replace_impl(match_spec, from, state)
  end

  @impl true
  def handle_call({:atomic_ets_op, op}, from, state) do
    atomic_ets_op_impl(op, from, state)
  end

  def handle_call(:check_index_consistency, from, state) do
    check_index_consistency_impl(from, state)
  end

  def handle_call({:range_create, document_id, owner}, from, state) do
    range_create_impl(document_id, owner, from, state)
  end

  def handle_call({:range_detach, range_id}, from, state) do
    range_detach_impl(range_id, from, state)
  end

  def handle_call({:text_split, node_id, offset}, from, state) do
    text_split_impl(node_id, offset, from, state)
  end

  def handle_call({:range_clone_contents, range_id}, from, state) do
    range_clone_contents_impl(range_id, from, state)
  end

  def handle_call({:range_extract_contents, range_id}, from, state) do
    range_extract_contents_impl(range_id, from, state)
  end

  def handle_call({:range_delete_contents, range_id}, from, state) do
    range_delete_contents_impl(range_id, from, state)
  end

  def handle_call({:range_insert_node, range_id, node_id}, from, state) do
    range_insert_node_impl(range_id, node_id, from, state)
  end

  def handle_call({:range_surround_contents, range_id, element_id}, from, state) do
    range_surround_contents_impl(range_id, element_id, from, state)
  end

  @impl true
  def handle_call({:append_child, parent_id, child_id}, from, state) do
    append_child_impl(parent_id, child_id, from, state)
  end

  @impl true
  def handle_call({:append_subtree, parent_id, child_id, subtree}, from, state) do
    append_subtree_impl(parent_id, child_id, subtree, from, state)
  end

  @impl true
  def handle_call({:insert_before, parent_id, child_id, reference_child_id}, from, state) do
    insert_before_impl(parent_id, child_id, reference_child_id, from, state)
  end

  @impl true
  def handle_call(
        {:insert_subtree, parent_id, child_id, reference_child_id, subtree},
        from,
        state
      ) do
    insert_subtree_impl(parent_id, child_id, reference_child_id, subtree, from, state)
  end

  @impl true
  def handle_call({:remove_child, parent_id, child_id}, from, state) do
    remove_child_impl(parent_id, child_id, from, state)
  end

  @impl true
  def handle_call({:replace_child, parent_id, new_child_id, old_child_id}, from, state) do
    replace_child_impl(parent_id, new_child_id, old_child_id, from, state)
  end

  @impl true
  def handle_call(
        {:replace_subtree, parent_id, new_child_id, old_child_id, subtree},
        from,
        state
      ) do
    replace_subtree_impl(parent_id, new_child_id, old_child_id, subtree, from, state)
  end

  @impl true
  def handle_call({:export_subtree, node_id}, from, state) do
    export_subtree_impl(node_id, from, state)
  end

  @impl true
  def handle_call({:remove_subtree, node_id}, from, state) do
    remove_subtree_impl(node_id, from, state)
  end

  @impl true
  def handle_call({:owner_document, node_id}, from, state) do
    owner_document_impl(node_id, from, state)
  end

  @impl true
  def handle_call({:clone_node, node_id, deep?}, from, state) do
    clone_node_impl(node_id, deep?, from, state)
  end

  @impl true
  def handle_call({:inner_html, node_id}, from, state) do
    inner_html_impl(node_id, from, state)
  end

  def handle_call({:set_inner_html, node_id, html}, from, state) do
    set_inner_html_impl(node_id, html, from, state)
  end

  def handle_call({:set_outer_html, node_id, html}, from, state) do
    set_outer_html_impl(node_id, html, from, state)
  end

  @impl true
  def handle_call({:outer_html, node_id}, from, state) do
    outer_html_impl(node_id, from, state)
  end

  @impl true
  def handle_call({:get_elements_by_tag_name, node_id, name}, from, state) do
    get_elements_by_tag_name_impl(node_id, name, from, state)
  end

  @impl true
  def handle_call({:get_element_by_id, root_id, id}, from, state) do
    get_element_by_id_impl(root_id, id, from, state)
  end

  @impl true
  def handle_call({:get_elements_by_class_name, root_id, names}, from, state) do
    get_elements_by_class_name_impl(root_id, names, from, state)
  end

  @impl true
  def handle_call({:query_selector, root_id, selector}, from, state) do
    query_selector_impl(root_id, selector, from, state)
  end

  @impl true
  def handle_call({:query_selector_all, root_id, selector}, from, state) do
    query_selector_all_impl(root_id, selector, from, state)
  end

  @impl true
  def handle_call({:matches, node_id, selector}, from, state) do
    matches_impl(node_id, selector, from, state)
  end

  @impl true
  def handle_call({:text_content, node_id}, from, state) do
    text_content_impl(node_id, from, state)
  end

  @impl true
  def handle_call({:set_text_content, node_id, value}, from, state) do
    set_text_content_impl(node_id, value, from, state)
  end

  @impl true
  def handle_call({:set_value, node_id, value}, from, state) do
    set_value_impl(node_id, value, from, state)
  end
end
