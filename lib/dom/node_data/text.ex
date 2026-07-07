defmodule DOM.NodeData.Text do
  @moduledoc "ETS record for a text node."

  defstruct [:value, parent: nil]

  use DOM.NodeData

  @type t :: %__MODULE__{value: String.t() | nil, parent: reference() | nil}

  @impl DOM.NodeData
  def type(_text), do: :text

  @impl DOM.NodeData
  def node_type(_text), do: 3

  @impl DOM.NodeData
  def node_name(_text), do: "#text"
end
