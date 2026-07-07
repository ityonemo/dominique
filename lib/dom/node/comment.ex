defmodule DOM.Node.Comment do
  @moduledoc """
  A handle to a comment node. Comment nodes are leaves that carry their text as
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
  def append_child(_comment, _child), do: raise(DOM.HierarchyRequestError)
  @impl DOM.Node
  def insert_before(_comment, _child, _reference_child), do: raise(DOM.HierarchyRequestError)
  @impl DOM.Node
  def child_nodes(_comment), do: []
  @impl DOM.Node
  def parent_node(comment), do: DOM._node_parent_node(comment.server, comment.id)
  @impl DOM.Node
  def value(comment), do: DOM._node_value(comment.server, comment.id)
  @impl DOM.Node
  def node_type(_comment), do: 8
  @impl DOM.Node
  def node_name(_comment), do: "#comment"
  @impl DOM.Node
  def text_content(comment), do: value(comment)
  @impl DOM.Node
  def set_text_content(comment, value), do: DOM._node_set_value(comment.server, comment.id, value)
end
