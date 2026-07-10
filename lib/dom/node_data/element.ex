defmodule DOM.NodeData.Element do
  @moduledoc "ETS record for an element node."

  @enforce_keys [:local_name]
  defstruct [
    :local_name,
    :content,
    namespace: :html,
    parent: nil,
    children: [],
    attributes: [],
    # Nested-set extent: `root` is the tree root's id; `{start, stop}` are binary
    # order-keys containing all descendants' extents. Dual-maintained with
    # `children` during the adjacency migration; see DOM.NodeData.Table.
    root: nil,
    start: nil,
    stop: nil
  ]

  use DOM.NodeData
  use DOM.HTML

  @type namespace :: :html | :svg | :mathml

  @type t :: %__MODULE__{
          local_name: String.t(),
          namespace: namespace(),
          content: reference() | nil,
          parent: reference() | nil,
          children: [reference()],
          attributes: [{String.t(), String.t()}],
          root: reference() | nil,
          start: binary() | nil,
          stop: binary() | nil
        }

  @impl DOM.NodeData
  def type(_element), do: :element

  @impl DOM.NodeData
  def node_type(_element), do: 1

  @impl DOM.NodeData
  def node_name(%{local_name: local_name}), do: local_name

  @impl DOM.HTML
  def serialize(%__MODULE__{local_name: name} = element, node_id, nodes) do
    start_tag = DOM.HTML.start_tag(name, element.attributes)

    if DOM.HTML.void?(name) do
      start_tag
    else
      child_ids = DOM.NodeData.Table.children_by_extent(nodes, node_id)
      [start_tag, DOM.HTML.children(name, child_ids, nodes), "</", name | ">"]
    end
  end
end
