defmodule DOM.Node.DocumentType do
  @moduledoc """
  A handle to a document type (doctype) node. Doctypes are leaves carrying
  `name`, `public_id`, and `system_id`, and reject children.
  """

  alias DOM.NodeData

  @enforce_keys [:server, :id]
  defstruct [:server, :id]

  use DOM.Node

  @type t :: %__MODULE__{server: GenServer.server(), id: reference()}

  @spec create(DOM.Node.Document.t(), String.t(), String.t(), String.t()) :: t()

  def create(document, name, public_id, system_id) do
    DOM._create(document, %NodeData{
      type: __MODULE__,
      name: name,
      public_id: public_id,
      system_id: system_id
    })
  end

  @impl DOM.Node
  def append_child(_document_type, _child), do: raise(DOM.HierarchyRequestError)

  @impl DOM.Node
  def insert_before(_document_type, _child, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  @impl DOM.Node
  def child_nodes(_document_type), do: []

  @impl DOM.Node
  def parent_node(document_type) do
    DOM._node_parent_node(document_type.server, document_type.id)
  end

  @impl DOM.Node
  def value(_document_type), do: nil
end
