defmodule DOM.NodeData.Document do
  @moduledoc "ETS record for the document node."

  # `root`/`start`/`stop`: the document is a tree root, so `parent` is nil and
  # `start`/`stop` are the fixed root extent (<<0x00>>..<<0x80>>). Dual-maintained
  # with `children`; see DOM.NodeData.Table.
  defstruct parent: nil, children: [], root: nil, start: nil, stop: nil

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{
          parent: nil,
          children: [reference()],
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
  def serialize(%__MODULE__{children: children}, nodes) do
    DOM.HTML.children("", children, nodes)
  end
end
