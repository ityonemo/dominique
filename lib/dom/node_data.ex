use Protoss

defprotocol DOM.NodeData do
  @moduledoc """
  The internal per-type node records stored in a document's ETS table, one
  struct per node kind (`DOM.NodeData.Element`, `Text`, `Comment`, `Document`,
  `DocumentFragment`, `DocumentType`). Never exposed to callers — user code holds
  `DOM.Node` handles; the server reads these structs out of the tuple space.

  The protocol carries the per-kind values the server dispatches on: the handle
  `type` atom, the DOM `nodeType` number, and the DOM `nodeName`. Structural
  fields (`parent`, `value`, `attributes`, `local_name`, the nested-set extent
  `root`/`start`/`stop`) are read as plain struct fields; `parent/1` in the `after`
  block wraps the common one. Child adjacency is NOT a field — it is derived from
  the extents (`DOM.NodeData.Table.children_by_extent/2`).
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
  @doc "Parent id of the record, or `nil`."
  def parent(%{parent: parent}), do: parent

  # Re-entrant twins of DOM._select_nodes/_select_index: when a read runs INSIDE
  # the document server (e.g. an event listener during dispatch), a GenServer.call
  # back into the same process would deadlock, so read the tid straight from the
  # process dictionary (stashed in DOM.init) and run the select in place. `server`
  # is ignored — the tables are process-ambient here.
  def _select_nodes(_server, select) do
    :nodes
    |> Process.get()
    |> :ets.select(select)
  end

  def _select_index(_server, select) do
    :index
    |> Process.get()
    |> :ets.select(select)
  end
end
