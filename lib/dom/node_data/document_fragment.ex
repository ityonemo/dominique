defmodule DOM.NodeData.DocumentFragment do
  @moduledoc "ETS record for a document fragment node."

  # `root`/`start`/`stop`: a fragment is a tree root (until adopted), so it carries
  # its own extent. Child adjacency is extent-borne (no `children` field); see
  # DOM.NodeData.NodesTable.
  use DOM.NodeData
  use DOM.HTML
  alias DOM.NodeData.NodesTable

  defstruct @enforce_keys ++ [:parent]

  @type t :: %__MODULE__{
          parent: nil,
          root: reference(),
          start: binary(),
          stop: binary()
        }

  @impl DOM.NodeData
  def type(_fragment), do: :document_fragment

  @impl DOM.NodeData
  def node_type(_fragment), do: 11

  @impl DOM.NodeData
  def node_name(_fragment), do: "#document-fragment"

  @impl DOM.HTML
  def serialize(%__MODULE__{}, node_id, nodes) do
    DOM.HTML.children("", NodesTable.children_by_extent(nodes, node_id), nodes)
  end
end
