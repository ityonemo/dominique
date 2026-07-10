defmodule DOM.NodeData.Text do
  @moduledoc "ETS record for a text node."

  # `root`/`start`/`stop`: a text node is a positioned leaf, so it carries an
  # extent under its parent. Dual-maintained with the parent's `children`.
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
  def type(_text), do: :text

  @impl DOM.NodeData
  def node_type(_text), do: 3

  @impl DOM.NodeData
  def node_name(_text), do: "#text"

  @impl DOM.HTML
  def serialize(%__MODULE__{value: value}, _nodes), do: DOM.HTML.escape_text(value)
end
