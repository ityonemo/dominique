use Protoss

defprotocol DOM.NodeData do
  @moduledoc """
  The internal per-type node records stored in a document's ETS table, one
  struct per node kind (`DOM.NodeData.Element`, `Text`, `Comment`, `Document`,
  `DocumentFragment`, `DocumentType`). Never exposed to callers — user code holds
  `DOM.Node` handles; the server reads these structs out of the tuple space.

  The protocol carries the per-kind values the server dispatches on: the handle
  `type` atom, the DOM `nodeType` number, and the DOM `nodeName`. Structural
  fields (`parent`, `children`, `value`, `attributes`, `local_name`) are read as
  plain struct fields; `parent/1` and `children/1` in the `after` block wrap the
  common ones so leaf kinds without a `children` field answer `[]`.
  """

  @type t ::
          DOM.NodeData.Element.t()
          | DOM.NodeData.Text.t()
          | DOM.NodeData.Comment.t()
          | DOM.NodeData.Document.t()
          | DOM.NodeData.DocumentFragment.t()
          | DOM.NodeData.DocumentType.t()

  @doc "The `DOM.Node` handle `type` atom (`:element`, `:text`, …)."
  def type(node_data)

  @doc "The DOM `nodeType` numeric constant."
  def node_type(node_data)

  @doc "The DOM `nodeName`."
  def node_name(node_data)
after
  @doc "Child ids of the record, or `[]` for leaf kinds without children."
  def children(%{children: children}), do: children
  def children(_leaf), do: []

  @doc "Parent id of the record, or `nil`."
  def parent(%{parent: parent}), do: parent
end
