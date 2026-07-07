defmodule DOM.Node.DocumentFragment do
  @moduledoc """
  A handle to a document fragment: a lightweight container whose children are
  moved into the target and left empty when the fragment is inserted.
  """

  alias DOM.NodeData

  @enforce_keys [:server, :id]
  defstruct [:server, :id]

  use DOM.Node

  @type t :: %__MODULE__{server: GenServer.server(), id: reference()}

  @spec create(DOM.Node.Document.t()) :: t()

  def create(document) do
    DOM._create(document, %NodeData{type: __MODULE__})
  end

  @impl DOM.Node
  def append_child(_fragment, %DOM.Node.Document{}), do: raise(DOM.HierarchyRequestError)

  def append_child(_fragment, %DOM.Node.DocumentType{}), do: raise(DOM.HierarchyRequestError)

  def append_child(fragment, child) do
    DOM._node_append_child(fragment.server, fragment.id, child)
  end

  @impl DOM.Node
  def insert_before(_fragment, %DOM.Node.Document{}, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  def insert_before(_fragment, %DOM.Node.DocumentType{}, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  def insert_before(fragment, child, reference_child) do
    DOM._node_insert_before(fragment.server, fragment.id, child, reference_child)
  end

  @impl DOM.Node
  def child_nodes(fragment), do: DOM._node_child_nodes(fragment.server, fragment.id)

  @impl DOM.Node
  def parent_node(fragment), do: DOM._node_parent_node(fragment.server, fragment.id)

  @impl DOM.Node
  def value(_fragment), do: nil

  @impl DOM.Node
  def node_type(_fragment), do: 11

  @impl DOM.Node
  def node_name(_fragment), do: "#document-fragment"

  @impl DOM.Node
  def text_content(fragment), do: DOM._node_text_content(fragment.server, fragment.id)

  @impl DOM.Node
  def set_text_content(fragment, value) do
    DOM._node_set_text_content(fragment.server, fragment.id, value)
  end
end
