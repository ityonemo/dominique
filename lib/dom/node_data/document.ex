defmodule DOM.NodeData.Document do
  @moduledoc "ETS record for the document node."

  defstruct parent: nil, children: []

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{parent: nil, children: [reference()]}

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
