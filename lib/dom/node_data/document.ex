defmodule DOM.NodeData.Document do
  @moduledoc "ETS record for the document node."

  defstruct parent: nil, children: []

  use DOM.NodeData

  @type t :: %__MODULE__{parent: nil, children: [reference()]}

  @impl DOM.NodeData
  def type(_document), do: :document

  @impl DOM.NodeData
  def node_type(_document), do: 9

  @impl DOM.NodeData
  def node_name(_document), do: "#document"
end
