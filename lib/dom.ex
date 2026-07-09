defmodule DOM do
  @moduledoc """
  A DOM document backed by a `GenServer` that owns a private ETS table of
  per-type `DOM.NodeData.*` records.

  Node handles are the single `DOM.Node` struct (`%DOM.Node{server, id, type}`),
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

  @enforce_keys [:nodes, :document_id]
  defstruct [:nodes, :document_id, :fragment_root]

  @type state :: %__MODULE__{
          nodes: :ets.tid(),
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
    :ets.insert(nodes, {document_id, %NodeData.Document{}})
    state = %__MODULE__{nodes: nodes, document_id: document_id}

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
  @spec _atomic_ets_op(GenServer.server(), (:ets.tid() -> result)) :: result when result: term()
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
    %Node{server: server, id: Keyword.fetch!(opts, :document_id), type: :document}
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
  def _element_content(%Node{server: server, id: id}) do
    GenServer.call(server, {:element_content, id})
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
    GenServer.call(document.server, {:get_elements_by_tag_name, document.id, name})
  end

  def get_element_by_id(document, id) do
    GenServer.call(document.server, {:get_element_by_id, document.id, id})
  end

  def get_elements_by_class_name(document, names) do
    GenServer.call(document.server, {:get_elements_by_class_name, document.id, names})
  end

  def query_selector(document, selector) do
    GenServer.call(document.server, {:query_selector, document.id, parse_selector!(selector)})
  end

  def query_selector_all(document, selector) do
    GenServer.call(document.server, {:query_selector_all, document.id, parse_selector!(selector)})
  end

  def matches(node, selector) do
    GenServer.call(node.server, {:matches, node.id, parse_selector!(selector)})
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
    TreeBuilder.build_into(state.nodes, state.document_id, tokens)
    {:noreply, state}
  end

  defp fragment_impl(tokens, context, state) do
    root_id = TreeBuilder.build_fragment_into(state.nodes, state.document_id, tokens, context)
    {:noreply, %{state | fragment_root: root_id}}
  end

  defp create_impl(node_data, _from, state) do
    node_id = make_ref()
    Table.put(state.nodes, node_id, node_data)
    {:reply, node_handle(state.nodes, node_id), state}
  end

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
    {:reply, op.(state.nodes), state}
  end

  def _node_append_child(server, parent_id, %{server: child_server, id: child_id} = child) do
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
        {:reply, :ok, state}

      :else ->
        Table.append_child(state.nodes, parent_id, child_id)
        {:reply, :ok, state}
    end
  end

  defp append_fragment(nodes, parent_id, fragment_id, fragment) do
    parent = fetch_node!(nodes, parent_id)
    reparent_fragment_children(nodes, parent_id, fragment)

    put_node(nodes, parent_id, %{parent | children: parent.children ++ fragment.children})
    put_node(nodes, fragment_id, %{fragment | children: []})
  end

  defp insert_fragment(nodes, parent_id, fragment_id, fragment, reference_child_id) do
    parent = fetch_node!(nodes, parent_id)
    reparent_fragment_children(nodes, parent_id, fragment)

    {before, after_reference} =
      Enum.split_while(parent.children, &(&1 != reference_child_id))

    put_node(nodes, parent_id, %{
      parent
      | children: before ++ fragment.children ++ after_reference
    })

    put_node(nodes, fragment_id, %{fragment | children: []})
  end

  defp reparent_fragment_children(nodes, parent_id, fragment) do
    Enum.each(fragment.children, fn child_id ->
      child = fetch_node!(nodes, child_id)
      put_node(nodes, child_id, %{child | parent: parent_id})
    end)
  end

  def _node_insert_before(server, parent_id, child, nil) do
    _node_append_child(server, parent_id, child)
  end

  def _node_insert_before(
        server,
        parent_id,
        %{server: child_server, id: child_id} = child,
        %{id: reference_child_id}
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

      reference_child_id not in parent_data.children ->
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
        {:reply, :ok, state}

      :else ->
        Table.insert_before(state.nodes, parent_id, child_id, reference_child_id)
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
      materialize_subtree(state.nodes, child_id, subtree)

      if match?(%NodeData.DocumentFragment{}, child_data) do
        append_fragment(state.nodes, parent_id, child_id, child_data)
      else
        put_node(state.nodes, parent_id, %{
          parent_data
          | children: parent_data.children ++ [child_id]
        })

        put_node(state.nodes, child_id, %{child_data | parent: parent_id})
      end

      {:reply, {:ok, node_handle(state.nodes, child_id)}, state}
    end
  end

  defp insert_subtree_impl(parent_id, child_id, reference_child_id, subtree, _from, state) do
    subtree_nodes = Map.new(subtree)
    child_data = Map.fetch!(subtree_nodes, child_id)
    parent_data = fetch_node!(state.nodes, parent_id)

    cond do
      reference_child_id not in parent_data.children ->
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
        materialize_subtree(state.nodes, child_id, subtree)

        if match?(%NodeData.DocumentFragment{}, child_data) do
          insert_fragment(state.nodes, parent_id, child_id, child_data, reference_child_id)
        else
          {before, after_reference} =
            Enum.split_while(parent_data.children, &(&1 != reference_child_id))

          put_node(state.nodes, parent_id, %{
            parent_data
            | children: before ++ [child_id | after_reference]
          })

          put_node(state.nodes, child_id, %{child_data | parent: parent_id})
        end

        {:reply, {:ok, node_handle(state.nodes, child_id)}, state}
    end
  end

  defp materialize_subtree(nodes, child_id, subtree) do
    subtree =
      Enum.map(subtree, fn
        {^child_id, node_data} -> {child_id, %{node_data | parent: nil}}
        entry -> entry
      end)

    true = :ets.insert(nodes, subtree)
  end

  def _node_remove_child(server, parent_id, %{id: child_id} = child) do
    case GenServer.call(server, {:remove_child, parent_id, child_id}) do
      :ok -> child
      {:error, :not_found} -> raise DOM.NotFoundError
    end
  end

  defp remove_child_impl(parent_id, child_id, _from, state) do
    parent_data = fetch_node!(state.nodes, parent_id)

    if child_id in parent_data.children do
      Table.remove_child(state.nodes, parent_id, child_id)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def _node_replace_child(
        server,
        parent_id,
        %{server: new_server, id: new_child_id},
        %{id: old_child_id} = old_child
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
      fn -> materialize_subtree(state.nodes, new_child_id, subtree) end,
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
      old_child_id not in parent_data.children ->
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
        detach_child(state.nodes, old_child_id)
        parent = fetch_node!(state.nodes, parent_id)
        {before, [^old_child_id | rest]} = split_at_child(parent.children, old_child_id)

        replacement =
          if match?(%NodeData.DocumentFragment{}, new_child_data) do
            reparent_fragment_children(state.nodes, parent_id, new_child_data)
            put_node(state.nodes, new_child_id, %{new_child_data | children: []})
            new_child_data.children
          else
            put_node(state.nodes, new_child_id, %{new_child_data | parent: parent_id})
            [new_child_id]
          end

        put_node(state.nodes, parent_id, %{parent | children: before ++ replacement ++ rest})
        {:reply, {:ok, node_handle(state.nodes, new_child_id)}, state}
    end
  end

  defp detach_child(nodes, child_id) do
    child = fetch_node!(nodes, child_id)
    put_node(nodes, child_id, %{child | parent: nil})
  end

  defp split_at_child(children, child_id) do
    Enum.split_while(children, &(&1 != child_id))
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

    state.nodes
    |> subtree(node_id)
    |> Enum.each(fn {id, _node_data} -> :ets.delete(state.nodes, id) end)

    {:reply, :ok, state}
  end

  defp invalid_hierarchy?(nodes, parent, parent_id, child, child_id, reference_child_id, subtree) do
    inclusive_ancestor?(nodes, child_id, parent_id) or
      (match?(%NodeData.Document{}, parent) and
         invalid_document_child?(nodes, parent, child, child_id, reference_child_id, subtree))
  end

  defp invalid_document_child?(
         nodes,
         document,
         %NodeData.Element{},
         child_id,
         reference_child_id,
         _sub
       ) do
    document_has_kind?(nodes, document, NodeData.Element, child_id) or
      doctype_at_or_after?(nodes, document, reference_child_id)
  end

  defp invalid_document_child?(
         nodes,
         document,
         %NodeData.DocumentType{},
         child_id,
         reference_id,
         _sub
       ) do
    document_has_kind?(nodes, document, NodeData.DocumentType, child_id) or
      element_before?(nodes, document, reference_id)
  end

  defp invalid_document_child?(
         nodes,
         document,
         %NodeData.DocumentFragment{} = fragment,
         _child_id,
         _reference_child_id,
         subtree
       ) do
    invalid_document_fragment?(nodes, document, fragment, subtree)
  end

  defp invalid_document_child?(_nodes, _document, _child, _child_id, _reference_child_id, _sub) do
    false
  end

  # An element precedes the insertion point: with a nil reference (append), any
  # element counts; otherwise only elements before the reference child.
  defp element_before?(nodes, document, reference_child_id) do
    document.children
    |> Enum.take_while(&(&1 != reference_child_id))
    |> Enum.any?(&match?(%NodeData.Element{}, fetch_node!(nodes, &1)))
  end

  # A doctype sits at or after the insertion point: with a nil reference
  # (append), any doctype counts; otherwise doctypes from the reference child on.
  defp doctype_at_or_after?(nodes, document, reference_child_id) do
    document.children
    |> Enum.drop_while(&(&1 != reference_child_id))
    |> Enum.any?(&match?(%NodeData.DocumentType{}, fetch_node!(nodes, &1)))
  end

  defp invalid_document_fragment?(nodes, document, fragment, subtree_nodes) do
    kinds =
      Enum.map(fragment.children, fn child_id ->
        node_kind(nodes, child_id, subtree_nodes)
      end)

    element_count = Enum.count(kinds, &(&1 == NodeData.Element))

    NodeData.Text in kinds or
      element_count > 1 or
      (element_count == 1 and document_has_kind?(nodes, document, NodeData.Element, nil))
  end

  # The NodeData struct MODULE of a node (used as a kind discriminator).
  defp node_kind(nodes, node_id, nil), do: fetch_node!(nodes, node_id).__struct__

  defp node_kind(_nodes, node_id, subtree_nodes),
    do: Map.fetch!(subtree_nodes, node_id).__struct__

  defp document_has_kind?(nodes, document, kind, except_id) do
    Enum.any?(document.children, fn node_id ->
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
        %Node{server: self(), id: state.document_id, type: :document}
      end

    {:reply, owner, state}
  end

  def _node_clone_node(server, node_id, deep?) do
    GenServer.call(server, {:clone_node, node_id, deep?})
  end

  defp clone_node_impl(node_id, deep?, _from, state) do
    clone_id = Table.clone(state.nodes, node_id, deep?)
    {:reply, node_handle(state.nodes, clone_id), state}
  end

  def _element_inner_html(server, node_id) do
    GenServer.call(server, {:inner_html, node_id})
  end

  defp inner_html_impl(node_id, _from, state) do
    element = fetch_node!(state.nodes, node_id)
    iodata = DOM.HTML.children(element.local_name, element.children, state.nodes)
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
    Enum.each(Table.children(state.nodes, root), &Table.append_child(state.nodes, node_id, &1))

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

      Enum.each(
        Table.children(state.nodes, root),
        &Table.insert_before(state.nodes, parent_id, &1, node_id)
      )

      Table.remove_child(state.nodes, parent_id, node_id)
      {:reply, :ok, state}
    end
  end

  # Fragment-parse `html` in `context` into this document's table; return the
  # synthetic fragment-root id (whose children are the parsed nodes).
  defp fragment_root_for(html, context, state) do
    tokens = DOM.HTML.fragment_tokens(html, context.name)
    TreeBuilder.build_fragment_into(state.nodes, state.document_id, tokens, context)
  end

  def _element_outer_html(server, node_id) do
    GenServer.call(server, {:outer_html, node_id})
  end

  defp outer_html_impl(node_id, _from, state) do
    iodata = state.nodes |> fetch_node!(node_id) |> DOM.HTML.serialize(state.nodes)
    {:reply, IO.iodata_to_binary(iodata), state}
  end

  defp get_elements_by_tag_name_impl(node_id, name, _from, state) do
    matches =
      state.nodes
      |> descendant_ids(node_id)
      |> Enum.filter(&tag_name_match?(state.nodes, &1, name))
      |> Enum.map(&node_handle(state.nodes, &1))

    {:reply, matches, state}
  end

  defp tag_name_match?(nodes, node_id, name) do
    node = fetch_node!(nodes, node_id)
    match?(%NodeData.Element{}, node) and (name == "*" or node.local_name == name)
  end

  defp get_element_by_id_impl(root_id, id, _from, state) do
    match_id =
      Enum.find(descendant_ids(state.nodes, root_id), fn node_id ->
        node = fetch_node!(state.nodes, node_id)
        match?(%NodeData.Element{}, node) and List.keyfind(node.attributes, "id", 0) == {"id", id}
      end)

    match = if match_id, do: node_handle(state.nodes, match_id)
    {:reply, match, state}
  end

  defp get_elements_by_class_name_impl(root_id, names, _from, state) do
    wanted = class_tokens(names)

    matches =
      if wanted == [] do
        []
      else
        state.nodes
        |> descendant_ids(root_id)
        |> Enum.filter(&class_name_match?(state.nodes, &1, wanted))
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
  defp matches_impl(node_id, selector, _from, state) do
    matched =
      Enum.any?(selector, fn complex -> DOM.CSS.match(complex, state.nodes, [node_id]) != [] end)

    {:reply, matched, state}
  end

  # Descendant element ids of `root_id` matching `selector`, in tree order. Each
  # complex in the selector list contributes its matches; the union is ordered by
  # the tree-order descendant walk.
  # `selector` arrives already parsed and validated by the caller (parse_selector!).
  defp query_ids(root_id, selector, state) do
    candidates = descendant_ids(state.nodes, root_id)

    matched =
      selector
      |> Enum.flat_map(fn complex -> DOM.CSS.match(complex, state.nodes, candidates) end)
      |> MapSet.new()

    Enum.filter(candidates, &MapSet.member?(matched, &1))
  end

  defp class_name_match?(nodes, node_id, wanted) do
    node = fetch_node!(nodes, node_id)

    with %NodeData.Element{} <- node,
         {"class", class} <- List.keyfind(node.attributes, "class", 0) do
      present = class_tokens(class)
      Enum.all?(wanted, &(&1 in present))
    else
      _ -> false
    end
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
    node = fetch_node!(state.nodes, node_id)
    Enum.each(node.children, &delete_subtree(state.nodes, &1))
    children = if value == "", do: [], else: [new_text(state.nodes, node_id, value)]
    put_node(state.nodes, node_id, %{node | children: children})
    {:reply, :ok, state}
  end

  defp delete_subtree(nodes, node_id) do
    nodes
    |> subtree(node_id)
    |> Enum.each(fn {id, _node_data} -> :ets.delete(nodes, id) end)
  end

  defp new_text(nodes, parent_id, value) do
    text_id = make_ref()
    :ets.insert(nodes, {text_id, %NodeData.Text{value: value, parent: parent_id}})
    text_id
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
    |> fetch_node!(node_id)
    |> NodeData.children()
    |> Enum.flat_map(&subtree(nodes, &1))
  end

  # ==========================================================================
  # Helper functions
  # ==========================================================================

  defp fetch_node!(nodes, node_id), do: Table.fetch!(nodes, node_id)

  defp put_node(nodes, node_id, node), do: Table.put(nodes, node_id, node)

  defp node_handle(nodes, node_id) do
    type = nodes |> fetch_node!(node_id) |> NodeData.type()
    %Node{server: self(), id: node_id, type: type}
  end

  defp subtree(nodes, node_id) do
    node_data = fetch_node!(nodes, node_id)

    [{node_id, node_data}] ++
      Enum.flat_map(NodeData.children(node_data), &subtree(nodes, &1))
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
