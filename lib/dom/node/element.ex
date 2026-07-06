defmodule DOM.Node.Element do
  @moduledoc """
  A handle to an element node. Elements may contain children and expose a
  `local_name`.
  """

  alias DOM.NodeData

  @enforce_keys [:server, :id]
  defstruct [:server, :id]

  use DOM.Node

  @type t :: %__MODULE__{server: GenServer.server(), id: reference()}

  @spec create(DOM.Node.Document.t(), String.t()) :: t()
  @spec local_name(t()) :: String.t()

  def create(document, local_name) do
    DOM._create(document, %NodeData{type: __MODULE__, local_name: local_name})
  end

  def local_name(element), do: DOM._element_local_name(element.server, element.id)

  @impl DOM.Node
  def append_child(_element, %DOM.Node.Document{}), do: raise(DOM.HierarchyRequestError)

  def append_child(_element, %DOM.Node.DocumentType{}), do: raise(DOM.HierarchyRequestError)

  def append_child(element, child), do: DOM._node_append_child(element.server, element.id, child)

  @impl DOM.Node
  def insert_before(_element, %DOM.Node.Document{}, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  def insert_before(_element, %DOM.Node.DocumentType{}, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  def insert_before(element, child, reference_child) do
    DOM._node_insert_before(element.server, element.id, child, reference_child)
  end

  @impl DOM.Node
  def child_nodes(element), do: DOM._node_child_nodes(element.server, element.id)

  @impl DOM.Node
  def parent_node(element), do: DOM._node_parent_node(element.server, element.id)

  @impl DOM.Node
  def value(element), do: DOM._node_value(element.server, element.id)

  @impl DOM.Node
  def node_type(_element), do: 1

  @impl DOM.Node
  def node_name(element), do: local_name(element)
end
