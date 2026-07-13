defmodule DOM.NodeData.ShadowRoot do
  @moduledoc """
  ETS record for a shadow root — a detached root tree (like a DocumentFragment)
  hosted by an element. `host` back-links to the host element; `mode` is `:open`
  or `:closed` (closed hides the root from `Element.shadowRoot`). Its extent
  fields make it its own nested-set root, coexisting with the document and any
  other detached roots in the nodes table.
  """

  use DOM.NodeData
  use DOM.HTML

  defstruct @enforce_keys ++ [:host, :parent, mode: :open, slot_assignment: :named]

  @type mode :: :open | :closed
  @type slot_assignment :: :named | :manual

  @type t :: %__MODULE__{
          host: reference() | nil,
          mode: mode(),
          slot_assignment: slot_assignment(),
          parent: reference() | nil,
          root: reference(),
          start: binary(),
          stop: binary()
        }

  @impl DOM.NodeData
  def type(_shadow_root), do: :shadow_root

  # A ShadowRoot shares DocumentFragment's nodeType/nodeName (11 /
  # "#document-fragment") per spec, though it is a distinct interface.
  @impl DOM.NodeData
  def node_type(_shadow_root), do: 11

  @impl DOM.NodeData
  def node_name(_shadow_root), do: "#document-fragment"

  # Serialize the shadow tree's children (used by ShadowRoot innerHTML; the host's
  # outerHTML never reaches here, since it reads the host's own children).
  @impl DOM.HTML
  def serialize(%__MODULE__{}, node_id, nodes) do
    DOM.HTML.children("", DOM.NodeData.Table.children_by_extent(nodes, node_id), nodes)
  end
end
