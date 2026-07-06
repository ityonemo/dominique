defmodule DOM.Node.Document do
  @moduledoc """
  A handle to the document node at the root of a DOM tree. A document admits at
  most one document element and one document type, and rejects other document
  and text children.
  """

  @enforce_keys [:server, :id]
  defstruct [:server, :id]

  use DOM.Node

  @type t :: %__MODULE__{server: GenServer.server(), id: reference()}

  @impl DOM.Node
  def append_child(_document, %__MODULE__{}), do: raise(DOM.HierarchyRequestError)

  def append_child(_document, %DOM.Node.Text{}), do: raise(DOM.HierarchyRequestError)

  def append_child(document, child) do
    DOM._node_append_child(document.server, document.id, child)
  end

  @impl DOM.Node
  def insert_before(_document, %__MODULE__{}, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  def insert_before(_document, %DOM.Node.Text{}, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  def insert_before(document, child, reference_child) do
    DOM._node_insert_before(document.server, document.id, child, reference_child)
  end

  @impl DOM.Node
  def child_nodes(document), do: DOM._node_child_nodes(document.server, document.id)

  @impl DOM.Node
  def parent_node(document), do: DOM._node_parent_node(document.server, document.id)

  @impl DOM.Node
  def value(document), do: DOM._node_value(document.server, document.id)

  @impl DOM.Node
  def node_type(_document), do: 9

  @impl DOM.Node
  def node_name(_document), do: "#document"
end
