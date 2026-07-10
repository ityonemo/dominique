defmodule DOM.NodeData.Document do
  @moduledoc "ETS record for the document node."

  # `root`/`start`/`stop`: the document is a tree root, so `parent` is nil and
  # `start`/`stop` are the fixed root extent (<<0x00>>..<<0x80>>). Child adjacency
  # is extent-borne (no `children` field); see DOM.NodeData.Table.
  defstruct parent: nil, root: nil, start: nil, stop: nil

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{
          parent: nil,
          root: reference() | nil,
          start: binary() | nil,
          stop: binary() | nil
        }

  @impl DOM.NodeData
  def type(_document), do: :document

  @impl DOM.NodeData
  def node_type(_document), do: 9

  @impl DOM.NodeData
  def node_name(_document), do: "#document"

  @impl DOM.HTML
  def serialize(%__MODULE__{}, node_id, nodes) do
    DOM.HTML.children("", DOM.NodeData.Table.children_by_extent(nodes, node_id), nodes)
  end
end
