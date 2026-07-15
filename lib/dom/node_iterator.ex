defmodule DOM.NodeIterator do
  @moduledoc """
  A NodeIterator (DOM `NodeIterator`) — a stateful, document-order cursor over a root's
  inclusive subtree, filtered by `whatToShow` + an optional callback. Create with
  `DOM.create_node_iterator/3`.

  `next_node/1` / `previous_node/1` advance the reference node and return the next/prev
  accepted node (or `nil` at the ends). The iteration set **includes the root**. The
  reference node is adjusted when a node is removed, so iteration survives removals.

  State lives in the server; the handle `%DOM.NodeIterator{server, ref}` stays valid as
  the cursor advances.
  """

  alias DOM.Node

  @enforce_keys [:server, :ref]
  defstruct [:server, :ref]

  @type t :: %__MODULE__{server: GenServer.server(), ref: reference()}

  @doc "The next accepted node in document order, advancing the iterator; `nil` at the end."
  @spec next_node(t()) :: Node.t() | nil
  def next_node(%__MODULE__{server: server, ref: ref}) do
    DOM._traversal_step(server, ref, &DOM._node_iterator_move(&1, &2, &3, :next))
  end

  @doc "The previous accepted node in document order, moving the iterator back; `nil` at the start."
  @spec previous_node(t()) :: Node.t() | nil
  def previous_node(%__MODULE__{server: server, ref: ref}) do
    DOM._traversal_step(server, ref, &DOM._node_iterator_move(&1, &2, &3, :prev))
  end

  @doc "The iterator's current reference node."
  @spec reference_node(t()) :: Node.t()
  def reference_node(%__MODULE__{server: server, ref: ref}) do
    DOM._traversal_node(server, ref, :reference)
  end
end
