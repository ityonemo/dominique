defmodule DOM.NodeData.Comment do
  @moduledoc "ETS record for a comment node."

  defstruct [:value, parent: nil]

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{value: String.t() | nil, parent: reference() | nil}

  @impl DOM.NodeData
  def type(_comment), do: :comment

  @impl DOM.NodeData
  def node_type(_comment), do: 8

  @impl DOM.NodeData
  def node_name(_comment), do: "#comment"

  @impl DOM.HTML
  def serialize(%__MODULE__{value: value}, _nodes), do: ["<!--", value | "-->"]
end
