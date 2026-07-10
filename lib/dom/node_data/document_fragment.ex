defmodule DOM.NodeData.DocumentFragment do
  @moduledoc "ETS record for a document fragment node."

  # `root`/`start`/`stop`: a fragment is a tree root (until adopted), so it carries
  # its own extent. Dual-maintained with `children`; see DOM.NodeData.Table.
  defstruct parent: nil, children: [], root: nil, start: nil, stop: nil

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{
          parent: reference() | nil,
          children: [reference()],
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
  def serialize(%__MODULE__{children: children}, nodes) do
    DOM.HTML.children("", children, nodes)
  end
end
