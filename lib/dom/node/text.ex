defmodule DOM.Node.Text do
  @moduledoc """
  A handle to a text node. Text nodes are leaves that carry character data as
  their `value` and reject children.
  """

  alias DOM.NodeData

  @enforce_keys [:server, :id]
  defstruct [:server, :id]

  use DOM.Node

  @type t :: %__MODULE__{server: GenServer.server(), id: reference()}

  @spec create(DOM.Node.Document.t(), String.t()) :: t()

  def create(document, value) do
    DOM._create(document, %NodeData{type: __MODULE__, value: value})
  end

  @impl DOM.Node
  def append_child(_text, _child), do: raise(DOM.HierarchyRequestError)
  @impl DOM.Node
  def insert_before(_text, _child, _reference_child), do: raise(DOM.HierarchyRequestError)
  @impl DOM.Node
  def child_nodes(_text), do: []
  @impl DOM.Node
  def parent_node(text), do: DOM._node_parent_node(text.server, text.id)
  @impl DOM.Node
  def value(text), do: DOM._node_value(text.server, text.id)
end
