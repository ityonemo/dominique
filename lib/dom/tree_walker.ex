defmodule DOM.TreeWalker do
  @moduledoc """
  A TreeWalker (DOM `TreeWalker`) — a stateful cursor over a root's subtree, filtered by
  `whatToShow` + an optional callback. Create with `DOM.create_tree_walker/3`.

  The navigation methods (`next_node`, `previous_node`, `parent_node`, `first_child`,
  `last_child`, `next_sibling`, `previous_sibling`) move `current_node` to the next
  matching node in the given direction and return it (or `nil`, per the DOM). `next_node`
  excludes the root. State lives in the server; the handle stays valid as it advances.

  A filter callback returns `:accept` (yield), `:skip` (don't yield but descend), or
  `:reject` (skip the node and its whole subtree). A `whatToShow`-excluded node is
  treated as `:skip`.
  """

  alias DOM.Node

  @enforce_keys [:server, :ref]
  defstruct [:server, :ref]

  @type t :: %__MODULE__{server: GenServer.server(), ref: reference()}

  @doc "The walker's current node."
  @spec current_node(t()) :: Node.t()
  def current_node(%__MODULE__{server: server, ref: ref}),
    do: DOM._traversal_node(server, ref, :current)

  @doc "Set the walker's current node."
  @spec set_current_node(t(), Node.t()) :: :ok
  def set_current_node(%__MODULE__{server: server, ref: ref}, %Node{node_id: node_id}),
    do: DOM._traversal_set_current(server, ref, node_id)

  @doc "Move to the next node in document order (excluding the root); `nil` at the end."
  @spec next_node(t()) :: Node.t() | nil
  def next_node(w), do: step(w, :next_node)

  @doc "Move to the previous node in document order; `nil` at the start."
  @spec previous_node(t()) :: Node.t() | nil
  def previous_node(w), do: step(w, :previous_node)

  @doc "Move to the current node's parent (that is within the root); `nil` if none."
  @spec parent_node(t()) :: Node.t() | nil
  def parent_node(w), do: step(w, :parent_node)

  @doc "Move to the current node's first matching child; `nil` if none."
  @spec first_child(t()) :: Node.t() | nil
  def first_child(w), do: step(w, :first_child)

  @doc "Move to the current node's last matching child; `nil` if none."
  @spec last_child(t()) :: Node.t() | nil
  def last_child(w), do: step(w, :last_child)

  @doc "Move to the current node's next matching sibling; `nil` if none."
  @spec next_sibling(t()) :: Node.t() | nil
  def next_sibling(w), do: step(w, :next_sibling)

  @doc "Move to the current node's previous matching sibling; `nil` if none."
  @spec previous_sibling(t()) :: Node.t() | nil
  def previous_sibling(w), do: step(w, :previous_sibling)

  defp step(%__MODULE__{server: server, ref: ref}, which) do
    DOM._traversal_step(server, ref, &DOM._tree_walker_move(&1, &2, &3, which))
  end
end
