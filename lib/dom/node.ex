defmodule DOM.Node do
  @moduledoc """
  A handle to a DOM node: `%DOM.Node{server, id, type}`, where `type` is the node
  kind (`:element`, `:text`, `:comment`, `:document`, `:document_fragment`,
  `:document_type`). Handles are immutable references into the owning document's
  GenServer, not live objects; a handle can go stale after a cross-document
  transfer (see the README).

  This module holds the **generic** node operations — those that apply to any
  node kind. Element-only operations live in `DOM.Element`; whole-document
  operations live in `DOM`. Operations whose result is fixed by the node kind
  fail fast client-side via `type`-guarded clauses; everything else calls the
  owning server through a `DOM._node_*` bridge.
  """

  @enforce_keys [:server, :id, :type]
  defstruct [:server, :id, :type]

  @type node_type ::
          :element | :text | :comment | :document | :document_fragment | :document_type

  @type t :: %__MODULE__{server: GenServer.server(), id: reference(), type: node_type()}

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

  def append_child(%__MODULE__{type: :document_fragment}, %__MODULE__{type: type})
      when type in [:document, :document_type] do
    raise DOM.HierarchyRequestError
  end

  def append_child(%__MODULE__{type: :document}, %__MODULE__{type: type})
      when type in [:document, :text] do
    raise DOM.HierarchyRequestError
  end

  def append_child(%__MODULE__{} = node, %__MODULE__{} = child) do
    DOM._node_append_child(node.server, node.id, child)
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

  def insert_before(%__MODULE__{type: :document_fragment}, %__MODULE__{type: type}, _reference)
      when type in [:document, :document_type] do
    raise DOM.HierarchyRequestError
  end

  def insert_before(%__MODULE__{type: :document}, %__MODULE__{type: type}, _reference)
      when type in [:document, :text] do
    raise DOM.HierarchyRequestError
  end

  def insert_before(%__MODULE__{} = node, %__MODULE__{} = child, reference_child) do
    DOM._node_insert_before(node.server, node.id, child, reference_child)
  end

  @doc "Removes `child` from `node` and returns it."
  @spec remove_child(t(), t()) :: t()
  def remove_child(%__MODULE__{} = node, %__MODULE__{} = child) do
    DOM._node_remove_child(node.server, node.id, child)
  end

  @doc "Replaces `old_child` with `new_child` under `node`, returning `old_child`."
  @spec replace_child(t(), t(), t()) :: t()
  def replace_child(%__MODULE__{} = node, %__MODULE__{} = new_child, %__MODULE__{} = old_child) do
    DOM._node_replace_child(node.server, node.id, new_child, old_child)
  end

  # ==========================================================================
  # Traversal
  # ==========================================================================

  @doc "The node's child nodes (always `[]` for leaf kinds)."
  @spec child_nodes(t()) :: [t()]
  def child_nodes(%__MODULE__{type: type}) when type in @leaf, do: []
  def child_nodes(%__MODULE__{} = node), do: DOM._node_child_nodes(node.server, node.id)

  @doc "The node's parent, or `nil`."
  @spec parent_node(t()) :: t() | nil
  def parent_node(%__MODULE__{} = node), do: DOM._node_parent_node(node.server, node.id)

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
      index = Enum.find_index(siblings, &(&1.id == node.id))
      target = index + offset
      if target >= 0, do: Enum.at(siblings, target)
    end
  end

  @doc "The document that owns `node`, or `nil` when `node` is the document."
  @spec owner_document(t()) :: t() | nil
  def owner_document(%__MODULE__{} = node), do: DOM._node_owner_document(node.server, node.id)

  # ==========================================================================
  # Inspection
  # ==========================================================================

  @doc "The DOM `nodeType` numeric constant."
  @spec node_type(t()) :: pos_integer()
  def node_type(%__MODULE__{} = node), do: DOM._node_node_type(node.server, node.id)

  @doc "The DOM `nodeName`."
  @spec node_name(t()) :: String.t()
  def node_name(%__MODULE__{} = node), do: DOM._node_node_name(node.server, node.id)

  @doc "The node's character data value (Text/Comment), else `nil`."
  @spec value(t()) :: String.t() | nil
  def value(%__MODULE__{} = node), do: DOM._node_value(node.server, node.id)

  @doc "The node's text content."
  @spec text_content(t()) :: String.t() | nil
  def text_content(%__MODULE__{type: type}) when type in [:document, :document_type], do: nil

  # Character-data nodes are their own text content; containers aggregate.
  def text_content(%__MODULE__{type: type} = node) when type in [:text, :comment] do
    DOM._node_value(node.server, node.id)
  end

  def text_content(%__MODULE__{} = node), do: DOM._node_text_content(node.server, node.id)

  @doc "Sets the node's text content."
  @spec set_text_content(t(), String.t()) :: :ok
  def set_text_content(%__MODULE__{type: type}, _value) when type in [:document, :document_type],
    do: :ok

  # Character-data nodes set their own value; containers replace their children.
  def set_text_content(%__MODULE__{type: type} = node, value) when type in [:text, :comment] do
    DOM._node_set_value(node.server, node.id, value)
  end

  def set_text_content(%__MODULE__{} = node, value) do
    DOM._node_set_text_content(node.server, node.id, value)
  end

  @doc "Clones `node` (deep when `deep?`), returning a fresh detached handle."
  @spec clone_node(t(), boolean()) :: t()
  def clone_node(%__MODULE__{} = node, deep? \\ false) do
    DOM._node_clone_node(node.server, node.id, deep?)
  end
end
