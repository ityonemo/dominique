defmodule DOM.NodeData.DocumentFragment do
  @moduledoc "ETS record for a document fragment node."

  # `root`/`start`/`stop`: a fragment is a tree root (until adopted), so it carries
  # its own extent. Child adjacency is extent-borne (no `children` field); see
  # DOM.NodeData.Table.
  defstruct parent: nil, root: nil, start: nil, stop: nil

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{
          parent: reference() | nil,
          root: reference() | nil,
          start: binary() | nil,
          stop: binary() | nil
        }

  @impl DOM.NodeData
  def type(_fragment), do: :document_fragment

  @impl DOM.NodeData
  def node_type(_fragment), do: 11

  @impl DOM.NodeData
  def node_name(_fragment), do: "#document-fragment"

  @impl DOM.HTML
  def serialize(%__MODULE__{}, node_id, nodes) do
    DOM.HTML.children("", DOM.NodeData.Table.children_by_extent(nodes, node_id), nodes)
  end
end
