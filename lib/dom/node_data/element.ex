defmodule DOM.NodeData.Element do
  @moduledoc "ETS record for an element node."

  @enforce_keys [:local_name]
  defstruct [:local_name, parent: nil, children: [], attributes: []]

  use DOM.NodeData

  @type t :: %__MODULE__{
          local_name: String.t(),
          parent: reference() | nil,
          children: [reference()],
          attributes: [{String.t(), String.t()}]
        }

  @impl DOM.NodeData
  def type(_element), do: :element

  @impl DOM.NodeData
  def node_type(_element), do: 1

  @impl DOM.NodeData
  def node_name(%{local_name: local_name}), do: local_name
end
