defmodule DOM.NodeData.DocumentType do
  @moduledoc "ETS record for a document type (doctype) node."

  @enforce_keys [:name]
  defstruct [:name, :public_id, :system_id, parent: nil]

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{
          name: String.t(),
          public_id: String.t() | nil,
          system_id: String.t() | nil,
          parent: reference() | nil
        }

  @impl DOM.NodeData
  def type(_document_type), do: :document_type

  @impl DOM.NodeData
  def node_type(_document_type), do: 10

  @impl DOM.NodeData
  def node_name(%{name: name}), do: name

  @impl DOM.HTML
  def serialize(%__MODULE__{name: name}, _nodes), do: ["<!DOCTYPE ", name | ">"]
end
