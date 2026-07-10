defmodule DOM.NodeData.DocumentType do
  @moduledoc "ETS record for a document type (doctype) node."

  @enforce_keys [:name]
  # `root`/`start`/`stop`: a doctype is a positioned leaf, so it carries an extent
  # under its parent. Dual-maintained with the parent's `children`.
  defstruct [:name, :public_id, :system_id, parent: nil, root: nil, start: nil, stop: nil]

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{
          name: String.t(),
          public_id: String.t() | nil,
          system_id: String.t() | nil,
          parent: reference() | nil,
          root: reference() | nil,
          start: binary() | nil,
          stop: binary() | nil
        }

  @impl DOM.NodeData
  def type(_document_type), do: :document_type

  @impl DOM.NodeData
  def node_type(_document_type), do: 10

  @impl DOM.NodeData
  def node_name(%{name: name}), do: name

  @impl DOM.HTML
  def serialize(%__MODULE__{name: name}, _node_id, _nodes), do: ["<!DOCTYPE ", name | ">"]
end
