defmodule DOM.NodeData.Comment do
  @moduledoc "ETS record for a comment node."

  # `root`/`start`/`stop`: a comment is a positioned leaf, so it carries an extent
  # under its parent. Dual-maintained with the parent's `children`.
  defstruct [:value, parent: nil, root: nil, start: nil, stop: nil]

  use DOM.NodeData
  use DOM.HTML

  @type t :: %__MODULE__{
          value: String.t() | nil,
          parent: reference() | nil,
          root: reference() | nil,
          start: binary() | nil,
          stop: binary() | nil
        }

  @impl DOM.NodeData
  def type(_comment), do: :comment

  @impl DOM.NodeData
  def node_type(_comment), do: 8

  @impl DOM.NodeData
  def node_name(_comment), do: "#comment"

  @impl DOM.HTML
  def serialize(%__MODULE__{value: value}, _nodes), do: ["<!--", value | "-->"]
end
