defmodule DOM.NodeData.DocumentType do
  @moduledoc "ETS record for a document type (doctype) node."

  # `root`/`start`/`stop`: a doctype is a positioned leaf, so it carries an extent
  # under its parent (enforced via DOM.NodeData); `:name` is enforced too.
  use DOM.NodeData
  use DOM.HTML

  @enforce_keys @enforce_keys ++ [:name]
  defstruct @enforce_keys ++ [:public_id, :system_id, :parent]

  @type t :: %__MODULE__{
          name: String.t(),
          public_id: String.t() | nil,
          system_id: String.t() | nil,
          parent: reference() | nil,
          root: reference(),
          start: binary(),
          stop: binary()
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
