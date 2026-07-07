defmodule DOM do
  @moduledoc """
  A DOM document backed by a `GenServer` that owns a private ETS table of
  `DOM.NodeData`.

  `DOM` is the context module for the `DOM.Node.Document` node type, EXCLUDING
  its `DOM.Node` protocol implementations (those live in `DOM.Node.Document`, as
  Protoss requires). Document-level operations (creating nodes, whole-document
  queries such as `get_elements_by_tag_name/2`) live here and take a
  `DOM.Node.Document` handle as their first argument, rather than being methods
  on the node struct. This mirrors the dispatch convention documented in
  `CLAUDE.md`: node-first operations belong on the `DOM.Node` protocol, while
  document-scoped operations belong on `DOM`. Accordingly `t/0` is the
  `DOM.Node.Document` handle type.

  The public node structs returned by this module (`DOM.Node.Element`,
  `DOM.Node.Text`, and friends) are immutable handles carrying the owning
  server and a node id; they are not live objects. Mutating operations run
  inside the server and may transfer whole subtrees between documents, after
  which a retained handle can become stale. See the project README for handle
  freshness rules.
  """

  use GenServer
  use MatchSpec

  alias DOM.Node
  alias DOM.Node.Comment
  alias DOM.Node.Document
  alias DOM.Node.DocumentFragment
  alias DOM.Node.DocumentType
  alias DOM.Node.Element
  alias DOM.Node.Text
  alias DOM.NodeData

  # ==========================================================================
  # Types
  # ==========================================================================

  @enforce_keys [:nodes, :document_id]
  defstruct [:nodes, :document_id]

  @type state :: %__MODULE__{
          nodes: :ets.tid(),
          document_id: reference()
        }

  @type t :: Document.t()

  # ==========================================================================
  # Lifecycle
  # ==========================================================================

  defp start_link(document_id) do
    GenServer.start_link(__MODULE__, document_id)
  end

  @impl true
  def init(document_id) do
    nodes = :ets.new(__MODULE__, [:set, :private])
    :ets.insert(nodes, {document_id, %NodeData{type: Document}})
    {:ok, %__MODULE__{nodes: nodes, document_id: document_id}}
  end

  # ==========================================================================
  # API
  # ==========================================================================

  @spec new() :: t()
  @spec create_element(Document.t(), String.t()) :: Element.t()
  @spec create_text_node(Document.t(), String.t()) :: Text.t()
  @spec create_comment(Document.t(), String.t()) :: Comment.t()
  @spec create_document_fragment(Document.t()) :: DocumentFragment.t()
  @spec create_document_type(Document.t(), String.t(), String.t(), String.t()) ::
          DocumentType.t()
  @spec get_elements_by_tag_name(Document.t(), String.t()) :: [Element.t()]
  @spec get_element_by_id(Document.t(), String.t()) :: Element.t() | nil
  @spec get_elements_by_class_name(Document.t(), String.t()) :: [Element.t()]
  @spec query_selector(Document.t(), String.t()) :: Element.t() | nil
  @spec query_selector_all(Document.t(), String.t()) :: [Element.t()]
  @spec _create(Document.t(), NodeData.t()) :: Node.t()
  @spec _node_append_child(GenServer.server(), reference(), Node.t()) :: Node.t()
  @spec _node_insert_before(GenServer.server(), reference(), Node.t(), Node.t() | nil) :: Node.t()
  @spec _node_remove_child(GenServer.server(), reference(), Node.t()) :: Node.t()
  @spec _node_replace_child(GenServer.server(), reference(), Node.t(), Node.t()) :: Node.t()
  @spec _node_owner_document(GenServer.server(), reference()) :: Document.t() | nil
  @spec _node_clone_node(GenServer.server(), reference(), boolean()) :: Node.t()
  @spec _export_subtree(GenServer.server(), reference()) :: [{reference(), NodeData.t()}]
  @spec _remove_subtree(GenServer.server(), reference()) :: :ok
  @spec _node_child_nodes(GenServer.server(), reference()) :: [Node.t()]
  @spec _node_parent_node(GenServer.server(), reference()) :: Node.t() | nil
  @spec _element_local_name(GenServer.server(), reference()) :: String.t()
  @spec _document_type_name(GenServer.server(), reference()) :: String.t()
  @spec _element_get_attribute(GenServer.server(), reference(), String.t()) :: String.t() | nil
  @spec _element_set_attribute(GenServer.server(), reference(), String.t(), String.t()) :: :ok
  @spec _element_has_attribute(GenServer.server(), reference(), String.t()) :: boolean()
  @spec _element_remove_attribute(GenServer.server(), reference(), String.t()) :: :ok
  @spec _element_get_attribute_names(GenServer.server(), reference()) :: [String.t()]
  @spec _node_value(GenServer.server(), reference()) :: String.t() | nil
  @spec _node_text_content(GenServer.server(), reference()) :: String.t()

  # ==========================================================================
  # Implementations
  # ==========================================================================

  def new do
    document_id = make_ref()
    {:ok, server} = start_link(document_id)
    %Document{server: server, id: document_id}
  end

  def create_element(document, local_name), do: Element.create(document, local_name)

  def create_text_node(document, value), do: Text.create(document, value)

  def create_comment(document, value), do: Comment.create(document, value)

  def create_document_fragment(document), do: DocumentFragment.create(document)

  def create_document_type(document, name, public_id, system_id) do
    DocumentType.create(document, name, public_id, system_id)
  end

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
    GenServer.call(document.server, {:query_selector, document.id, selector})
  end

  def query_selector_all(document, selector) do
    GenServer.call(document.server, {:query_selector_all, document.id, selector})
  end

  def _create(%Document{} = document, nodedata) do
    GenServer.call(document.server, {:create, nodedata})
  end

  def _create(_node, _nodedata), do: raise(DOM.HierarchyRequestError)

  defp create_impl(node_data, state) do
    node_id = make_ref()
    :ets.insert(state.nodes, {node_id, node_data})
    {:reply, node_handle(state.nodes, node_id), state}
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

  defp append_child_impl(parent_id, child_id, state) do
    child_data = fetch_node!(state.nodes, child_id)
    parent_data = fetch_node!(state.nodes, parent_id)

    cond do
      invalid_hierarchy?(state.nodes, parent_data, parent_id, child_data, child_id, nil, nil) ->
        {:reply, {:error, :hierarchy_request}, state}

      child_data.type == DocumentFragment ->
        append_fragment(state.nodes, parent_id, child_id, child_data)
        {:reply, :ok, state}

      :else ->
        detach_from_parent(state.nodes, child_id, child_data)
        parent = fetch_node!(state.nodes, parent_id)

        put_node(state.nodes, parent_id, %{parent | children: parent.children ++ [child_id]})
        put_node(state.nodes, child_id, %{child_data | parent: parent_id})
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

  defp insert_before_impl(parent_id, child_id, reference_child_id, state) do
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

      child_data.type == DocumentFragment ->
        insert_fragment(state.nodes, parent_id, child_id, child_data, reference_child_id)
        {:reply, :ok, state}

      :else ->
        detach_from_parent(state.nodes, child_id, child_data)
        parent = fetch_node!(state.nodes, parent_id)

        {before, [reference_child | after_reference]} =
          Enum.split_while(parent.children, &(&1 != reference_child_id))

        put_node(state.nodes, parent_id, %{
          parent
          | children: before ++ [child_id, reference_child | after_reference]
        })

        put_node(state.nodes, child_id, %{child_data | parent: parent_id})
        {:reply, :ok, state}
    end
  end

  defp append_subtree_impl(parent_id, child_id, subtree, state) do
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

      if child_data.type == DocumentFragment do
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

  defp insert_subtree_impl(parent_id, child_id, reference_child_id, subtree, state) do
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

        if child_data.type == DocumentFragment do
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

  defp remove_child_impl(parent_id, child_id, state) do
    parent_data = fetch_node!(state.nodes, parent_id)

    if child_id in parent_data.children do
      child_data = fetch_node!(state.nodes, child_id)

      put_node(state.nodes, parent_id, %{
        parent_data
        | children: List.delete(parent_data.children, child_id)
      })

      put_node(state.nodes, child_id, %{child_data | parent: nil})
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

  defp replace_child_impl(parent_id, new_child_id, old_child_id, state) do
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

  defp replace_subtree_impl(parent_id, new_child_id, old_child_id, subtree, state) do
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
          if new_child_data.type == DocumentFragment do
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

  defp export_subtree_impl(node_id, state) do
    {:reply, subtree(state.nodes, node_id), state}
  end

  def _remove_subtree(server, node_id) do
    GenServer.call(server, {:remove_subtree, node_id})
  end

  defp remove_subtree_impl(node_id, state) do
    node_data = fetch_node!(state.nodes, node_id)
    detach_from_parent(state.nodes, node_id, node_data)

    state.nodes
    |> subtree(node_id)
    |> Enum.each(fn {id, _node_data} -> :ets.delete(state.nodes, id) end)

    {:reply, :ok, state}
  end

  defp invalid_hierarchy?(nodes, parent, parent_id, child, child_id, reference_child_id, subtree) do
    inclusive_ancestor?(nodes, child_id, parent_id) or
      (parent.type == Document and
         invalid_document_child?(nodes, parent, child, child_id, reference_child_id, subtree))
  end

  defp invalid_document_child?(
         nodes,
         document,
         %{type: Element},
         child_id,
         reference_child_id,
         _sub
       ) do
    document_has_node_type?(nodes, document, Element, child_id) or
      doctype_at_or_after?(nodes, document, reference_child_id)
  end

  defp invalid_document_child?(
         nodes,
         document,
         %{type: DocumentType},
         child_id,
         reference_id,
         _sub
       ) do
    document_has_node_type?(nodes, document, DocumentType, child_id) or
      element_before?(nodes, document, reference_id)
  end

  defp invalid_document_child?(
         nodes,
         document,
         %{type: DocumentFragment} = fragment,
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
    |> Enum.any?(&(fetch_node!(nodes, &1).type == Element))
  end

  # A doctype sits at or after the insertion point: with a nil reference
  # (append), any doctype counts; otherwise doctypes from the reference child on.
  defp doctype_at_or_after?(nodes, document, reference_child_id) do
    document.children
    |> Enum.drop_while(&(&1 != reference_child_id))
    |> Enum.any?(&(fetch_node!(nodes, &1).type == DocumentType))
  end

  defp invalid_document_fragment?(nodes, document, fragment, subtree_nodes) do
    child_types =
      Enum.map(fragment.children, fn child_id ->
        node_type(nodes, child_id, subtree_nodes)
      end)

    element_count = Enum.count(child_types, &(&1 == Element))

    Text in child_types or
      element_count > 1 or
      (element_count == 1 and document_has_node_type?(nodes, document, Element, nil))
  end

  defp node_type(nodes, node_id, nil), do: fetch_node!(nodes, node_id).type
  defp node_type(_nodes, node_id, subtree_nodes), do: Map.fetch!(subtree_nodes, node_id).type

  defp document_has_node_type?(nodes, document, type, except_id) do
    Enum.any?(document.children, fn node_id ->
      node_id != except_id and fetch_node!(nodes, node_id).type == type
    end)
  end

  defp detach_from_parent(nodes, child_id, child) do
    if parent_id = child.parent do
      parent = fetch_node!(nodes, parent_id)
      put_node(nodes, parent_id, %{parent | children: List.delete(parent.children, child_id)})
    end
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

  def _node_child_nodes(server, node_id) do
    GenServer.call(server, {:child_nodes, node_id})
  end

  defp child_nodes_impl(node_id, state) do
    node = fetch_node!(state.nodes, node_id)
    children = Enum.map(node.children, &node_handle(state.nodes, &1))

    {:reply, children, state}
  end

  def _node_parent_node(server, node_id) do
    GenServer.call(server, {:parent_node, node_id})
  end

  defp parent_node_impl(node_id, state) do
    parent =
      if parent_id = fetch_node!(state.nodes, node_id).parent do
        node_handle(state.nodes, parent_id)
      end

    {:reply, parent, state}
  end

  def _node_owner_document(server, node_id) do
    GenServer.call(server, {:owner_document, node_id})
  end

  defp owner_document_impl(node_id, state) do
    owner =
      if node_id != state.document_id do
        %Document{server: self(), id: state.document_id}
      end

    {:reply, owner, state}
  end

  def _node_clone_node(server, node_id, deep?) do
    GenServer.call(server, {:clone_node, node_id, deep?})
  end

  defp clone_node_impl(node_id, deep?, state) do
    clone_id = clone_subtree(state.nodes, node_id, deep?)
    {:reply, node_handle(state.nodes, clone_id), state}
  end

  # Copies node_id's data under a fresh id with no parent. When deep?, its
  # children are cloned recursively and attached; otherwise the clone is a leaf.
  defp clone_subtree(nodes, node_id, deep?) do
    node_data = fetch_node!(nodes, node_id)
    clone_id = make_ref()

    children =
      if deep? do
        Enum.map(node_data.children, fn child_id ->
          child_clone_id = clone_subtree(nodes, child_id, true)
          child_clone = fetch_node!(nodes, child_clone_id)
          put_node(nodes, child_clone_id, %{child_clone | parent: clone_id})
          child_clone_id
        end)
      else
        []
      end

    put_node(nodes, clone_id, %{node_data | parent: nil, children: children})
    clone_id
  end

  def _element_local_name(server, node_id) do
    GenServer.call(server, {:local_name, node_id})
  end

  defp local_name_impl(node_id, state) do
    local_name = fetch_node!(state.nodes, node_id).local_name
    {:reply, local_name, state}
  end

  def _element_get_elements_by_tag_name(server, node_id, name) do
    GenServer.call(server, {:get_elements_by_tag_name, node_id, name})
  end

  defp get_elements_by_tag_name_impl(node_id, name, state) do
    matches =
      state.nodes
      |> descendant_ids(node_id)
      |> Enum.filter(&tag_name_match?(state.nodes, &1, name))
      |> Enum.map(&node_handle(state.nodes, &1))

    {:reply, matches, state}
  end

  defp tag_name_match?(nodes, node_id, name) do
    node = fetch_node!(nodes, node_id)
    node.type == Element and (name == "*" or node.local_name == name)
  end

  defp get_element_by_id_impl(root_id, id, state) do
    match_id =
      Enum.find(descendant_ids(state.nodes, root_id), fn node_id ->
        node = fetch_node!(state.nodes, node_id)
        node.type == Element and List.keyfind(node.attributes, "id", 0) == {"id", id}
      end)

    match = if match_id, do: node_handle(state.nodes, match_id)
    {:reply, match, state}
  end

  defp get_elements_by_class_name_impl(root_id, names, state) do
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

  defp query_selector_all_impl(root_id, selector, state) do
    ids = query_ids(root_id, selector, state)
    {:reply, Enum.map(ids, &node_handle(state.nodes, &1)), state}
  end

  defp query_selector_impl(root_id, selector, state) do
    match =
      case query_ids(root_id, selector, state) do
        [id | _] -> node_handle(state.nodes, id)
        [] -> nil
      end

    {:reply, match, state}
  end

  defp matches_impl(node_id, selector, state) do
    matched =
      selector
      |> DOM.CSS.parse()
      |> Enum.any?(fn complex -> DOM.CSS.match(complex, state.nodes, [node_id]) != [] end)

    {:reply, matched, state}
  end

  # Descendant element ids of `root_id` matching `selector`, in tree order. Each
  # complex in the selector list contributes its matches; the union is ordered by
  # the tree-order descendant walk.
  defp query_ids(root_id, selector, state) do
    candidates = descendant_ids(state.nodes, root_id)

    matched =
      selector
      |> DOM.CSS.parse()
      |> Enum.flat_map(fn complex -> DOM.CSS.match(complex, state.nodes, candidates) end)
      |> MapSet.new()

    Enum.filter(candidates, &MapSet.member?(matched, &1))
  end

  defp class_name_match?(nodes, node_id, wanted) do
    node = fetch_node!(nodes, node_id)

    with true <- node.type == Element,
         {"class", class} <- List.keyfind(node.attributes, "class", 0) do
      present = class_tokens(class)
      Enum.all?(wanted, &(&1 in present))
    else
      _ -> false
    end
  end

  defp class_tokens(names), do: String.split(names)

  def _element_get_attribute(server, node_id, name) do
    GenServer.call(server, {:get_attribute, node_id, name})
  end

  defp get_attribute_impl(node_id, name, state) do
    attributes = fetch_node!(state.nodes, node_id).attributes

    value =
      case List.keyfind(attributes, name, 0) do
        {^name, value} -> value
        nil -> nil
      end

    {:reply, value, state}
  end

  def _element_set_attribute(server, node_id, name, value) do
    GenServer.call(server, {:set_attribute, node_id, name, value})
  end

  defp set_attribute_impl(node_id, name, value, state) do
    node = fetch_node!(state.nodes, node_id)
    attributes = List.keystore(node.attributes, name, 0, {name, value})
    put_node(state.nodes, node_id, %{node | attributes: attributes})
    {:reply, :ok, state}
  end

  def _element_has_attribute(server, node_id, name) do
    GenServer.call(server, {:has_attribute, node_id, name})
  end

  defp has_attribute_impl(node_id, name, state) do
    present = List.keymember?(fetch_node!(state.nodes, node_id).attributes, name, 0)
    {:reply, present, state}
  end

  def _element_remove_attribute(server, node_id, name) do
    GenServer.call(server, {:remove_attribute, node_id, name})
  end

  defp remove_attribute_impl(node_id, name, state) do
    node = fetch_node!(state.nodes, node_id)
    put_node(state.nodes, node_id, %{node | attributes: List.keydelete(node.attributes, name, 0)})
    {:reply, :ok, state}
  end

  def _element_get_attribute_names(server, node_id) do
    GenServer.call(server, {:get_attribute_names, node_id})
  end

  defp get_attribute_names_impl(node_id, state) do
    names = Enum.map(fetch_node!(state.nodes, node_id).attributes, fn {name, _value} -> name end)
    {:reply, names, state}
  end

  def _document_type_name(server, node_id) do
    GenServer.call(server, {:document_type_name, node_id})
  end

  defp document_type_name_impl(node_id, state) do
    {:reply, fetch_node!(state.nodes, node_id).name, state}
  end

  def _node_value(server, node_id) do
    GenServer.call(server, {:value, node_id})
  end

  defp value_impl(node_id, state) do
    value = fetch_node!(state.nodes, node_id).value
    {:reply, value, state}
  end

  def _node_text_content(server, node_id) do
    GenServer.call(server, {:text_content, node_id})
  end

  defp text_content_impl(node_id, state) do
    text =
      state.nodes
      |> descendants(node_id)
      |> Enum.filter(&(&1.type == Text))
      |> Enum.map_join("", & &1.value)

    {:reply, text, state}
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
    fetch_node!(nodes, node_id).children
    |> Enum.flat_map(&subtree(nodes, &1))
  end

  # ==========================================================================
  # Helper functions
  # ==========================================================================

  defmatchspecp fetch_node(node_id) do
    {^node_id, node_data} -> node_data
  end

  defp fetch_node!(nodes, node_id) do
    [node_data] = :ets.select(nodes, fetch_node(node_id))
    node_data
  end

  defp put_node(nodes, node_id, node) do
    true = :ets.insert(nodes, {node_id, node})
    :ok
  end

  defp node_handle(nodes, node_id) do
    nodes
    |> fetch_node!(node_id)
    |> Map.fetch!(:type)
    |> struct!(server: self(), id: node_id)
  end

  defp subtree(nodes, node_id) do
    node_data = fetch_node!(nodes, node_id)

    [{node_id, node_data}] ++
      Enum.flat_map(node_data.children, &subtree(nodes, &1))
  end

  # ==========================================================================
  # Router
  # ==========================================================================

  @impl true
  def handle_call({:create, node_data}, _from, state) do
    create_impl(node_data, state)
  end

  @impl true
  def handle_call({:append_child, parent_id, child_id}, _from, state) do
    append_child_impl(parent_id, child_id, state)
  end

  @impl true
  def handle_call({:append_subtree, parent_id, child_id, subtree}, _from, state) do
    append_subtree_impl(parent_id, child_id, subtree, state)
  end

  @impl true
  def handle_call({:insert_before, parent_id, child_id, reference_child_id}, _from, state) do
    insert_before_impl(parent_id, child_id, reference_child_id, state)
  end

  @impl true
  def handle_call(
        {:insert_subtree, parent_id, child_id, reference_child_id, subtree},
        _from,
        state
      ) do
    insert_subtree_impl(parent_id, child_id, reference_child_id, subtree, state)
  end

  @impl true
  def handle_call({:remove_child, parent_id, child_id}, _from, state) do
    remove_child_impl(parent_id, child_id, state)
  end

  @impl true
  def handle_call({:replace_child, parent_id, new_child_id, old_child_id}, _from, state) do
    replace_child_impl(parent_id, new_child_id, old_child_id, state)
  end

  @impl true
  def handle_call(
        {:replace_subtree, parent_id, new_child_id, old_child_id, subtree},
        _from,
        state
      ) do
    replace_subtree_impl(parent_id, new_child_id, old_child_id, subtree, state)
  end

  @impl true
  def handle_call({:export_subtree, node_id}, _from, state) do
    export_subtree_impl(node_id, state)
  end

  @impl true
  def handle_call({:remove_subtree, node_id}, _from, state) do
    remove_subtree_impl(node_id, state)
  end

  @impl true
  def handle_call({:child_nodes, node_id}, _from, state) do
    child_nodes_impl(node_id, state)
  end

  @impl true
  def handle_call({:parent_node, node_id}, _from, state) do
    parent_node_impl(node_id, state)
  end

  @impl true
  def handle_call({:owner_document, node_id}, _from, state) do
    owner_document_impl(node_id, state)
  end

  @impl true
  def handle_call({:clone_node, node_id, deep?}, _from, state) do
    clone_node_impl(node_id, deep?, state)
  end

  @impl true
  def handle_call({:local_name, node_id}, _from, state) do
    local_name_impl(node_id, state)
  end

  @impl true
  def handle_call({:get_elements_by_tag_name, node_id, name}, _from, state) do
    get_elements_by_tag_name_impl(node_id, name, state)
  end

  @impl true
  def handle_call({:get_element_by_id, root_id, id}, _from, state) do
    get_element_by_id_impl(root_id, id, state)
  end

  @impl true
  def handle_call({:get_elements_by_class_name, root_id, names}, _from, state) do
    get_elements_by_class_name_impl(root_id, names, state)
  end

  @impl true
  def handle_call({:query_selector, root_id, selector}, _from, state) do
    query_selector_impl(root_id, selector, state)
  end

  @impl true
  def handle_call({:query_selector_all, root_id, selector}, _from, state) do
    query_selector_all_impl(root_id, selector, state)
  end

  @impl true
  def handle_call({:matches, node_id, selector}, _from, state) do
    matches_impl(node_id, selector, state)
  end

  @impl true
  def handle_call({:get_attribute, node_id, name}, _from, state) do
    get_attribute_impl(node_id, name, state)
  end

  @impl true
  def handle_call({:set_attribute, node_id, name, value}, _from, state) do
    set_attribute_impl(node_id, name, value, state)
  end

  @impl true
  def handle_call({:has_attribute, node_id, name}, _from, state) do
    has_attribute_impl(node_id, name, state)
  end

  @impl true
  def handle_call({:remove_attribute, node_id, name}, _from, state) do
    remove_attribute_impl(node_id, name, state)
  end

  @impl true
  def handle_call({:get_attribute_names, node_id}, _from, state) do
    get_attribute_names_impl(node_id, state)
  end

  @impl true
  def handle_call({:document_type_name, node_id}, _from, state) do
    document_type_name_impl(node_id, state)
  end

  @impl true
  def handle_call({:value, node_id}, _from, state) do
    value_impl(node_id, state)
  end

  @impl true
  def handle_call({:text_content, node_id}, _from, state) do
    text_content_impl(node_id, state)
  end
end
