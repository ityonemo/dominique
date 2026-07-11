defmodule DOM.Node do
  @moduledoc """
  A handle to a DOM node: `%DOM.Node{server, node_id, type}`, where `type` is the node
  kind (`:element`, `:text`, `:comment`, `:document`, `:document_fragment`,
  `:document_type`, `:shadow_root`). Handles are immutable references into the owning document's
  GenServer, not live objects; a handle can go stale after a cross-document
  transfer (see the README).

  This module holds the **generic** node operations — those that apply to any
  node kind. Element-only operations live in `DOM.Element`; whole-document
  operations live in `DOM`. Operations whose result is fixed by the node kind
  fail fast client-side via `type`-guarded clauses. Row-local reads drive the ETS
  table through `DOM._select_nodes` with a `defmatchspecp` whose body builds the result
  (often a `%DOM.Node{}` handle, one clause per `DOM.NodeData.*` record); the rest
  call the owning server through a `DOM._node_*` bridge.
  """

  use MatchSpec

  alias DOM.NodeData

  @enforce_keys [:server, :node_id, :type]
  defstruct [:server, :node_id, :type]

  @type node_type ::
          :element
          | :text
          | :comment
          | :document
          | :document_fragment
          | :document_type
          | :shadow_root

  @type t :: %__MODULE__{server: GenServer.server(), node_id: reference(), type: node_type()}

  @leaf [:text, :comment, :document_type]

  # ==========================================================================
  # Tree mutation
  # ==========================================================================

  @doc "Appends `child` to `node`, returning the (possibly transferred) child."
  @spec append_child(t(), t()) :: t()
  def append_child(%__MODULE__{type: type}, _child) when type in @leaf do
    raise DOM.HierarchyRequestError
  end

  def append_child(%__MODULE__{type: :element}, %__MODULE__{type: type})
      when type in [:document, :document_type] do
    raise DOM.HierarchyRequestError
  end

  def append_child(%__MODULE__{type: type}, %__MODULE__{type: child_type})
      when type in [:document_fragment, :shadow_root] and
             child_type in [:document, :document_type] do
    raise DOM.HierarchyRequestError
  end

  def append_child(%__MODULE__{type: :document}, %__MODULE__{type: type})
      when type in [:document, :text] do
    raise DOM.HierarchyRequestError
  end

  def append_child(%__MODULE__{} = node, %__MODULE__{} = child) do
    DOM._node_append_child(node.server, node.node_id, child)
  end

  @doc "Inserts `child` before `reference_child` (or appends when it is `nil`)."
  @spec insert_before(t(), t(), t() | nil) :: t()
  def insert_before(%__MODULE__{type: type}, _child, _reference) when type in @leaf do
    raise DOM.HierarchyRequestError
  end

  def insert_before(%__MODULE__{type: :element}, %__MODULE__{type: type}, _reference)
      when type in [:document, :document_type] do
    raise DOM.HierarchyRequestError
  end

  def insert_before(%__MODULE__{type: type}, %__MODULE__{type: child_type}, _reference)
      when type in [:document_fragment, :shadow_root] and
             child_type in [:document, :document_type] do
    raise DOM.HierarchyRequestError
  end

  def insert_before(%__MODULE__{type: :document}, %__MODULE__{type: type}, _reference)
      when type in [:document, :text] do
    raise DOM.HierarchyRequestError
  end

  def insert_before(%__MODULE__{} = node, %__MODULE__{} = child, reference_child) do
    DOM._node_insert_before(node.server, node.node_id, child, reference_child)
  end

  @doc "Removes `child` from `node` and returns it."
  @spec remove_child(t(), t()) :: t()
  def remove_child(%__MODULE__{} = node, %__MODULE__{} = child) do
    DOM._node_remove_child(node.server, node.node_id, child)
  end

  @doc "Replaces `old_child` with `new_child` under `node`, returning `old_child`."
  @spec replace_child(t(), t(), t()) :: t()
  def replace_child(%__MODULE__{} = node, %__MODULE__{} = new_child, %__MODULE__{} = old_child) do
    DOM._node_replace_child(node.server, node.node_id, new_child, old_child)
  end

  # ==========================================================================
  # Traversal
  # ==========================================================================

  @doc "The node's child nodes (always `[]` for leaf kinds)."
  @spec child_nodes(t()) :: [t()]
  def child_nodes(%__MODULE__{type: type}) when type in @leaf, do: []

  def child_nodes(%__MODULE__{} = node) do
    # The span index yields the ordered child ids in one range scan; map each to
    # its handle. Both reads run in one atomic op so the tree can't mutate between.
    server = node.server

    DOM._atomic_ets_op(server, fn nodes, index ->
      nodes
      |> DOM.NodeData.Table.span_children_of(index, node.node_id)
      |> Enum.map(fn child_id ->
        [handle] = :ets.select(nodes, handle_spec(server, child_id))
        handle
      end)
    end)
  end

  @doc "The node's parent, or `nil`."
  @spec parent_node(t()) :: t() | nil
  def parent_node(%__MODULE__{} = node) do
    # Two dependent reads (parent id, then that id's handle) run in one atomic op
    # so the tree can't be mutated between them.
    DOM._atomic_ets_op(node.server, fn nodes, _index ->
      case :ets.select(nodes, parent_id_spec(node.node_id)) do
        [nil] ->
          nil

        [parent_id] ->
          [handle] = :ets.select(nodes, handle_spec(node.server, parent_id))
          handle
      end
    end)
  end

  defmatchspecp parent_id_spec(node_id) do
    {^node_id, %{parent: parent}} -> parent
  end

  # Maps each record's `__struct__` to its `%DOM.Node{}` handle in one hit.
  defmatchspecp handle_spec(server, node_id) do
    {^node_id, %{__struct__: NodeData.Element}} ->
      %DOM.Node{server: server, node_id: node_id, type: :element}

    {^node_id, %{__struct__: NodeData.Text}} ->
      %DOM.Node{server: server, node_id: node_id, type: :text}

    {^node_id, %{__struct__: NodeData.Comment}} ->
      %DOM.Node{server: server, node_id: node_id, type: :comment}

    {^node_id, %{__struct__: NodeData.Document}} ->
      %DOM.Node{server: server, node_id: node_id, type: :document}

    {^node_id, %{__struct__: NodeData.DocumentType}} ->
      %DOM.Node{server: server, node_id: node_id, type: :document_type}

    {^node_id, %{__struct__: NodeData.DocumentFragment}} ->
      %DOM.Node{server: server, node_id: node_id, type: :document_fragment}

    {^node_id, %{__struct__: NodeData.ShadowRoot}} ->
      %DOM.Node{server: server, node_id: node_id, type: :shadow_root}
  end

  @doc "The node's first child, or `nil`."
  @spec first_child(t()) :: t() | nil
  def first_child(node), do: node |> child_nodes() |> List.first()

  @doc "The node's last child, or `nil`."
  @spec last_child(t()) :: t() | nil
  def last_child(node), do: node |> child_nodes() |> List.last()

  @doc "The node following this one under its parent, or `nil`."
  @spec next_sibling(t()) :: t() | nil
  def next_sibling(node), do: sibling(node, 1)

  @doc "The node preceding this one under its parent, or `nil`."
  @spec previous_sibling(t()) :: t() | nil
  def previous_sibling(node), do: sibling(node, -1)

  defp sibling(node, offset) do
    if parent = parent_node(node) do
      siblings = child_nodes(parent)
      index = Enum.find_index(siblings, &(&1.node_id == node.node_id))
      target = index + offset
      if target >= 0, do: Enum.at(siblings, target)
    end
  end

  @doc "The document that owns `node`, or `nil` when `node` is the document."
  @spec owner_document(t()) :: t() | nil
  def owner_document(%__MODULE__{} = node),
    do: DOM._node_owner_document(node.server, node.node_id)

  @doc "The `<slot>` this node is assigned to (shadow slotting), or `nil`."
  @spec assigned_slot(t()) :: t() | nil
  def assigned_slot(%__MODULE__{} = node),
    do: DOM._node_assigned_slot(node.server, node.node_id)

  @doc """
  The node's root — its tree root (a document, shadow root, or detached fragment).
  With `composed? == true`, cross shadow boundaries via each shadow root's host,
  returning the shadow-including (composed) root.
  """
  @spec get_root_node(t(), boolean()) :: t()
  def get_root_node(%__MODULE__{} = node, composed? \\ false),
    do: DOM._node_get_root_node(node.server, node.node_id, composed?)

  # ==========================================================================
  # ParentNode / ChildNode / sibling-element mixins
  # ==========================================================================

  @doc "The node's ELEMENT children, in document order (ParentNode.children)."
  @spec children(t()) :: [t()]
  def children(%__MODULE__{} = node) do
    node |> child_nodes() |> Enum.filter(&(&1.type == :element))
  end

  @doc "The first element child, or `nil`."
  @spec first_element_child(t()) :: t() | nil
  def first_element_child(%__MODULE__{} = node), do: node |> children() |> List.first()

  @doc "The last element child, or `nil`."
  @spec last_element_child(t()) :: t() | nil
  def last_element_child(%__MODULE__{} = node), do: node |> children() |> List.last()

  @doc "The number of element children."
  @spec child_element_count(t()) :: non_neg_integer()
  def child_element_count(%__MODULE__{} = node), do: node |> children() |> length()

  @doc "The previous ELEMENT sibling, or `nil`."
  @spec previous_element_sibling(t()) :: t() | nil
  def previous_element_sibling(%__MODULE__{} = node), do: element_sibling(node, :prev)

  @doc "The next ELEMENT sibling, or `nil`."
  @spec next_element_sibling(t()) :: t() | nil
  def next_element_sibling(%__MODULE__{} = node), do: element_sibling(node, :next)

  defp element_sibling(node, direction) do
    case parent_node(node) do
      nil -> nil
      parent -> sibling_at(children(parent), node.node_id, direction)
    end
  end

  # The element sibling before/after `node_id` in `siblings`, or nil. A nil index
  # (node_id is not itself an element) yields no element sibling by this API.
  defp sibling_at(siblings, node_id, direction) do
    case {Enum.find_index(siblings, &(&1.node_id == node_id)), direction} do
      {nil, _} -> nil
      {0, :prev} -> nil
      {idx, :prev} -> Enum.at(siblings, idx - 1)
      {idx, :next} -> Enum.at(siblings, idx + 1)
    end
  end

  @doc "Removes `node` from its parent (a no-op when it has none)."
  @spec remove(t()) :: :ok
  def remove(%__MODULE__{} = node) do
    if parent = parent_node(node), do: remove_child(parent, node)
    :ok
  end

  @doc "Inserts `others` into `node`'s parent immediately before `node`."
  @spec before(t(), [t() | String.t()]) :: :ok
  def before(%__MODULE__{} = node, others) do
    if parent = parent_node(node) do
      Enum.each(coerce(node, others), &insert_before(parent, &1, node))
    end

    :ok
  end

  # `after` is a reserved word in Elixir (try/receive), so the ChildNode.after()
  # method is defined via unquote to keep the DOM name.
  @doc "Inserts `others` into `node`'s parent immediately after `node`."
  @spec unquote(:after)(t(), [t() | String.t()]) :: :ok
  def unquote(:after)(%__MODULE__{} = node, others) do
    if parent = parent_node(node) do
      reference = next_sibling(node)
      Enum.each(coerce(node, others), &insert_before(parent, &1, reference))
    end

    :ok
  end

  @doc "Replaces `node` with `others` in its parent."
  @spec replace_with(t(), [t() | String.t()]) :: :ok
  def replace_with(%__MODULE__{} = node, others) do
    if parent = parent_node(node) do
      reference = next_sibling(node)
      remove_child(parent, node)
      Enum.each(coerce(node, others), &insert_before(parent, &1, reference))
    end

    :ok
  end

  @doc "Appends `others` as the last children of `node`."
  @spec append(t(), [t() | String.t()]) :: :ok
  def append(%__MODULE__{} = node, others) do
    Enum.each(coerce(node, others), &append_child(node, &1))
    :ok
  end

  @doc "Inserts `others` as the first children of `node`."
  @spec prepend(t(), [t() | String.t()]) :: :ok
  def prepend(%__MODULE__{} = node, others) do
    reference = first_child(node)
    Enum.each(coerce(node, others), &insert_before(node, &1, reference))
    :ok
  end

  # Coerce a ChildNode/ParentNode arg list to nodes: strings become Text nodes in
  # `reference`'s document. Nodes pass through unchanged.
  defp coerce(%__MODULE__{} = reference, others) do
    document = owner_document(reference) || reference
    Enum.map(others, &coerce_one(document, &1))
  end

  defp coerce_one(_document, %__MODULE__{} = node), do: node
  defp coerce_one(document, text) when is_binary(text), do: DOM.create_text_node(document, text)

  @doc """
  Normalizes `node`'s subtree: merges each run of adjacent Text siblings into the
  first (concatenating their data) and removes empty Text nodes, recursively.
  """
  @spec normalize(t()) :: :ok
  def normalize(%__MODULE__{} = node) do
    DOM._node_normalize(node.server, node.node_id)
  end

  # ==========================================================================
  # Comparison
  # ==========================================================================

  @doc "Whether `other` is an inclusive descendant of `node` (`node contains other`)."
  @spec contains(t(), t() | nil) :: boolean()
  def contains(%__MODULE__{}, nil), do: false

  def contains(%__MODULE__{server: server} = node, %__MODULE__{server: server} = other) do
    DOM._node_contains(server, node.node_id, other.node_id)
  end

  def contains(%__MODULE__{}, %__MODULE__{}), do: false

  @doc "Whether `node` has any child nodes."
  @spec has_child_nodes(t()) :: boolean()
  def has_child_nodes(%__MODULE__{} = node), do: child_nodes(node) != []

  # DOM method names (isConnected/isSameNode/isEqualNode) keep the `is_` prefix for
  # spec fidelity; the credo predicate-naming check is disabled for them.

  @doc "Whether `node` is connected — its shadow-including root is a document."
  @spec is_connected(t()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_connected(%__MODULE__{} = node), do: get_root_node(node, true).type == :document

  @doc "Whether `node` and `other` are the same node (identity)."
  @spec is_same_node(t(), t() | nil) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_same_node(%__MODULE__{} = node, %__MODULE__{} = other),
    do: node.server == other.server and node.node_id == other.node_id

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_same_node(%__MODULE__{}, nil), do: false

  @doc """
  Whether `node` and `other` are structurally equal — same kind, name, attributes
  (order-insensitive), character-data value, and, recursively, equal children in
  order. Identity is not required.
  """
  @spec is_equal_node(t(), t() | nil) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_equal_node(%__MODULE__{}, nil), do: false

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_equal_node(%__MODULE__{} = node, %__MODULE__{} = other) do
    DOM._node_is_equal(node.server, node.node_id, other.server, other.node_id)
  end

  @doc """
  A `Node.compareDocumentPosition` bitmask relating `other` to `node`:
  `DISCONNECTED (1)`, `PRECEDING (2)`, `FOLLOWING (4)`, `CONTAINS (8)`,
  `CONTAINED_BY (16)`, `IMPLEMENTATION_SPECIFIC (32)`. Disconnected nodes get a
  stable but implementation-specific direction.
  """
  @spec compare_document_position(t(), t()) :: non_neg_integer()
  def compare_document_position(%__MODULE__{} = node, %__MODULE__{} = other) do
    DOM._node_compare_document_position(node.server, node.node_id, other.server, other.node_id)
  end

  # ==========================================================================
  # Inspection
  # ==========================================================================

  @doc "The DOM `nodeType` numeric constant."
  @spec node_type(t()) :: pos_integer()
  def node_type(%__MODULE__{} = node) do
    [node_type] = DOM._select_nodes(node.server, node_type_spec(node.node_id))
    node_type
  end

  defmatchspecp node_type_spec(node_id) do
    {^node_id, %{__struct__: NodeData.Element}} -> 1
    {^node_id, %{__struct__: NodeData.Text}} -> 3
    {^node_id, %{__struct__: NodeData.Comment}} -> 8
    {^node_id, %{__struct__: NodeData.Document}} -> 9
    {^node_id, %{__struct__: NodeData.DocumentType}} -> 10
    {^node_id, %{__struct__: NodeData.DocumentFragment}} -> 11
    {^node_id, %{__struct__: NodeData.ShadowRoot}} -> 11
  end

  @doc "The DOM `nodeName`."
  @spec node_name(t()) :: String.t()
  def node_name(%__MODULE__{} = node) do
    [node_name] = DOM._select_nodes(node.server, node_name_spec(node.node_id))
    node_name
  end

  defmatchspecp node_name_spec(node_id) do
    {^node_id, %{__struct__: NodeData.Element, local_name: local_name}} -> local_name
    {^node_id, %{__struct__: NodeData.Text}} -> "#text"
    {^node_id, %{__struct__: NodeData.Comment}} -> "#comment"
    {^node_id, %{__struct__: NodeData.Document}} -> "#document"
    {^node_id, %{__struct__: NodeData.DocumentType, name: name}} -> name
    {^node_id, %{__struct__: NodeData.DocumentFragment}} -> "#document-fragment"
    {^node_id, %{__struct__: NodeData.ShadowRoot}} -> "#document-fragment"
  end

  @doc "A DocumentType's `{public_id, system_id}` (each `nil` when absent)."
  @spec doctype_ids(t()) :: {String.t() | nil, String.t() | nil}
  def doctype_ids(%__MODULE__{type: :document_type} = node) do
    [ids] = DOM._select_nodes(node.server, doctype_ids_spec(node.node_id))
    ids
  end

  defmatchspecp doctype_ids_spec(node_id) do
    {^node_id, %{__struct__: NodeData.DocumentType, public_id: p, system_id: s}} -> {p, s}
  end

  @doc "The node's character data value (Text/Comment), else `nil`."
  @spec value(t()) :: String.t() | nil
  def value(%__MODULE__{} = node) do
    [value] = DOM._select_nodes(node.server, value_spec(node.node_id))
    value
  end

  defmatchspecp value_spec(node_id) do
    {^node_id, %{__struct__: NodeData.Text, value: value}} -> value
    {^node_id, %{__struct__: NodeData.Comment, value: value}} -> value
    {^node_id, %{__struct__: NodeData.Element}} -> nil
    {^node_id, %{__struct__: NodeData.Document}} -> nil
    {^node_id, %{__struct__: NodeData.DocumentType}} -> nil
    {^node_id, %{__struct__: NodeData.DocumentFragment}} -> nil
  end

  @doc "The node's text content."
  @spec text_content(t()) :: String.t() | nil
  def text_content(%__MODULE__{type: type}) when type in [:document, :document_type], do: nil

  # Character-data nodes are their own text content; containers aggregate.
  def text_content(%__MODULE__{type: type} = node) when type in [:text, :comment] do
    value(node)
  end

  def text_content(%__MODULE__{} = node), do: DOM._node_text_content(node.server, node.node_id)

  @doc "Sets the node's text content."
  @spec set_text_content(t(), String.t()) :: :ok
  def set_text_content(%__MODULE__{type: type}, _value) when type in [:document, :document_type],
    do: :ok

  # Character-data nodes set their own value; containers replace their children.
  def set_text_content(%__MODULE__{type: type} = node, value) when type in [:text, :comment] do
    DOM._node_set_value(node.server, node.node_id, value)
  end

  def set_text_content(%__MODULE__{} = node, value) do
    DOM._node_set_text_content(node.server, node.node_id, value)
  end

  @doc "Clones `node` (deep when `deep?`), returning a fresh detached handle."
  @spec clone_node(t(), boolean()) :: t()
  def clone_node(%__MODULE__{} = node, deep? \\ false) do
    DOM._node_clone_node(node.server, node.node_id, deep?)
  end

  # ==========================================================================
  # Events (EventTarget — every node kind is an EventTarget)
  # ==========================================================================

  @doc """
  Registers `fun` as a listener for `type` events on `node`. `opts`: `:capture`
  (fire in the capturing phase), `:once` (auto-remove after one dispatch),
  `:passive` (`preventDefault` from the listener is ignored). Re-registering the
  same `(type, fun, capture)` is a no-op, per the DOM.
  """
  @spec add_event_listener(t(), String.t(), (DOM.Event.t() -> any()), keyword()) :: :ok
  def add_event_listener(%__MODULE__{} = node, type, fun, opts \\ [])
      when is_binary(type) and is_function(fun, 1) do
    listener = %DOM.Listener{
      type: type,
      fn: fun,
      capture: Keyword.get(opts, :capture, false),
      once: Keyword.get(opts, :once, false),
      passive: Keyword.get(opts, :passive, false)
    }

    DOM._node_add_event_listener(node.server, node.node_id, listener)
  end

  @doc """
  Removes the listener matching `(type, fun, capture)` from `node`. A no-op when
  none matches. Only `:capture` is significant for the match (per the DOM).
  """
  @spec remove_event_listener(t(), String.t(), (DOM.Event.t() -> any()), keyword()) :: :ok
  def remove_event_listener(%__MODULE__{} = node, type, fun, opts \\ [])
      when is_binary(type) and is_function(fun, 1) do
    capture = Keyword.get(opts, :capture, false)
    DOM._node_remove_event_listener(node.server, node.node_id, type, fun, capture)
  end

  @doc """
  Dispatch `event` at `node`, running its listeners. Returns `false` if the event
  was cancelled (a listener called `preventDefault` on a cancelable event), else
  `true` — the DOM's `dispatchEvent` boolean.
  """
  @spec dispatch_event(t(), DOM.Event.t()) :: boolean()
  def dispatch_event(%__MODULE__{} = node, %DOM.Event{} = event) do
    DOM._node_dispatch_event(node.server, node.node_id, event)
  end

  @doc """
  The composed path an `event` would traverse if dispatched at `node` — the nodes
  from `node` outward to the root, crossing shadow boundaries only when the event
  is `composed`. Mirrors `Event.composedPath()` (computed for a given target).
  """
  @spec composed_path(t(), DOM.Event.t()) :: [t()]
  def composed_path(%__MODULE__{} = node, %DOM.Event{composed: composed?}) do
    DOM._node_composed_path(node.server, node.node_id, composed?)
  end

  @doc false
  # Test-only introspection: a node's registered listeners in registration order.
  def __listeners(%__MODULE__{} = node) do
    DOM._node_listeners(node.server, node.node_id)
  end
end
