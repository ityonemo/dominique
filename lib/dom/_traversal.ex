defmodule DOM.Traversal do
  @moduledoc false

  # Shared tree-traversal engine for TreeWalker and NodeIterator (DOM §6.1–6.2). Pure
  # walking over the node table (`nodes` tid) — no server state. Operates on node ids;
  # the callers (DOM.TreeWalker / DOM.NodeIterator impls) own the stateful current /
  # reference node and the filter invocation, but the STEP logic lives here.
  #
  # `filter` is a 1-arg fun (node_id -> :accept | :skip | :reject) that already folds in
  # whatToShow (a non-shown node returns :skip). It runs in the server (re-entrant).

  alias DOM.NodeData
  alias DOM.NodeData.NodesTable

  # Whether `node_id`'s type is shown by the `what_to_show` bitmask. The DOM constant
  # for a node type N is (1 <<< (N - 1)); :all is every bit set.
  import Bitwise

  @doc "Is `node_id` shown by the whatToShow mask? (`:all` or an integer bitmask.)"
  @spec shown?(:ets.tid(), reference(), :all | non_neg_integer()) :: boolean()
  def shown?(_nodes, _id, :all), do: true

  def shown?(nodes, id, mask) when is_integer(mask) do
    (mask &&& 1 <<< (node_type(nodes, id) - 1)) != 0
  end

  defp node_type(nodes, id), do: nodes |> NodesTable.fetch!(id) |> NodeData.node_type()

  # ==========================================================================
  # NodeIterator: document-order next / previous over the root's inclusive subtree.
  # No REJECT pruning (a rejected node behaves like SKIP — filter already maps it).
  # ==========================================================================

  @doc """
  The next accepted node in document order strictly after `from` (a "before/after"
  pointer isn't needed here — the NodeIterator impl handles the pointer flag), within
  `root`'s inclusive subtree, or nil. `from == nil` means "start before root" (yields
  the first accepted node, root included).
  """
  @spec ni_next(:ets.tid(), reference(), reference() | nil, (reference() -> atom())) ::
          reference() | nil
  def ni_next(nodes, root, from, filter) do
    start = if from, do: following_in(nodes, root, from), else: root
    ni_scan(nodes, root, start, filter, &following_in/3)
  end

  @doc "The previous accepted node in document order before `from`, or nil."
  @spec ni_prev(:ets.tid(), reference(), reference() | nil, (reference() -> atom())) ::
          reference() | nil
  def ni_prev(nodes, root, from, filter) do
    start = if from, do: preceding_in(nodes, root, from), else: nil
    ni_scan(nodes, root, start, filter, &preceding_in/3)
  end

  # Scan from `node` in the given direction, returning the first that the filter accepts
  # (SKIP/REJECT both continue — NodeIterator does not prune subtrees).
  defp ni_scan(_nodes, _root, nil, _filter, _step), do: nil

  defp ni_scan(nodes, root, node, filter, step) do
    if filter.(node) == :accept do
      node
    else
      ni_scan(nodes, root, step.(nodes, root, node), filter, step)
    end
  end

  # ==========================================================================
  # TreeWalker: next / previous / nav from `current`, with REJECT pruning subtrees.
  # Each returns the new accepted node id (the caller sets currentNode to it), or nil.
  # ==========================================================================

  # nextNode (DOM §"traverse"): visit `current`'s descendants then following nodes in
  # document order; the first ACCEPTed node is returned. REJECT prunes the subtree.
  @spec tw_next(:ets.tid(), reference(), reference(), (reference() -> atom())) ::
          reference() | nil
  def tw_next(nodes, root, current, filter), do: tw_next_from(nodes, root, current, filter)

  defp tw_next_from(nodes, root, node, filter) do
    # descend to first child unless the node was rejected/skipped-with-no-children path;
    # walk in document order, but on REJECT skip the whole subtree.
    child = first_child_candidate(nodes, node)
    tw_next_step(nodes, root, node, child, filter)
  end

  # From `node`, having considered descending to `child` (or nil): find the next accepted.
  defp tw_next_step(nodes, root, node, child, filter) do
    cond do
      child != nil ->
        case filter.(child) do
          :accept -> child
          :skip -> tw_next_step(nodes, root, child, first_child_candidate(nodes, child), filter)
          :reject -> tw_next_after_subtree(nodes, root, node, child, filter)
        end

      :else ->
        # no children to descend: move to the following node (sibling / ancestor sibling)
        case tw_following(nodes, root, node) do
          nil -> nil
          following -> tw_visit_following(nodes, root, following, filter)
        end
    end
  end

  # child was REJECTed: skip its subtree, try its next sibling, else climb.
  defp tw_next_after_subtree(nodes, root, node, child, filter) do
    case next_sibling(nodes, child) do
      nil -> tw_next_step(nodes, root, node, nil, filter)
      sibling -> tw_visit_following(nodes, root, sibling, filter)
    end
  end

  # Consider `following` (already a candidate node in document order): accept it, skip
  # into its children, or reject-and-continue past it.
  defp tw_visit_following(nodes, root, node, filter) do
    case filter.(node) do
      :accept ->
        node

      :skip ->
        case first_child_candidate(nodes, node) do
          nil -> continue_after(nodes, root, node, filter)
          child -> tw_visit_following(nodes, root, child, filter)
        end

      :reject ->
        continue_after(nodes, root, node, filter)
    end
  end

  defp continue_after(nodes, root, node, filter) do
    case tw_following(nodes, root, node) do
      nil -> nil
      following -> tw_visit_following(nodes, root, following, filter)
    end
  end

  # The following node for TreeWalker stepping: next sibling, else climb to an ancestor's
  # next sibling, staying within root. (Descent is handled by the caller.)
  defp tw_following(nodes, root, id) do
    case next_sibling(nodes, id) do
      nil ->
        parent = NodesTable.parent(nodes, id)
        if parent == nil or id == root, do: nil, else: tw_following(nodes, root, parent)

      sibling ->
        sibling
    end
  end

  defp first_child_candidate(nodes, id) do
    case NodesTable.children(nodes, id) do
      [first | _] -> first
      [] -> nil
    end
  end

  # previousNode: the previous node in document order that is accepted, REJECT pruning
  # (a rejected node's subtree is not descended into during the backward walk).
  @spec tw_previous(:ets.tid(), reference(), reference(), (reference() -> atom())) ::
          reference() | nil
  def tw_previous(nodes, root, current, filter) do
    if current == root do
      nil
    else
      case prev_sibling(nodes, current) do
        nil -> tw_prev_parent(nodes, root, current, filter)
        sibling -> tw_prev_from_sibling(nodes, root, sibling, filter)
      end
    end
  end

  # Walk into the previous sibling's deepest accepted last-descendant.
  defp tw_prev_from_sibling(nodes, root, node, filter) do
    case filter.(node) do
      :reject ->
        tw_prev_skip_to(nodes, root, node, filter)

      result ->
        deepest = tw_deepest_accepted(nodes, node, filter)

        cond do
          deepest != nil -> deepest
          result == :accept -> node
          :else -> tw_prev_skip_to(nodes, root, node, filter)
        end
    end
  end

  # From a rejected/exhausted node, continue backward: its previous sibling, else parent.
  defp tw_prev_skip_to(nodes, root, node, filter) do
    case prev_sibling(nodes, node) do
      nil -> tw_prev_parent(nodes, root, node, filter)
      sibling -> tw_prev_from_sibling(nodes, root, sibling, filter)
    end
  end

  defp tw_prev_parent(nodes, root, node, filter) do
    parent = NodesTable.parent(nodes, node)

    cond do
      # previousNode never yields the root (mirrors nextNode excluding it).
      parent == nil or node == root or parent == root -> nil
      filter.(parent) == :accept -> parent
      :else -> tw_previous(nodes, root, parent, filter)
    end
  end

  # The deepest last-descendant of `node` that is accepted (descending through accepted/
  # skipped children, not rejected ones), or nil if none in the subtree.
  defp tw_deepest_accepted(nodes, node, filter) do
    case NodesTable.children(nodes, node) do
      [] -> nil
      children -> tw_last_accepted_descendant(children, nodes, filter)
    end
  end

  defp tw_last_accepted_descendant(children, nodes, filter) do
    children
    |> Enum.reverse()
    |> Enum.find_value(fn child ->
      case filter.(child) do
        :reject ->
          nil

        :accept ->
          tw_deepest_accepted(nodes, child, filter) || child

        :skip ->
          tw_deepest_accepted(nodes, child, filter)
      end
    end)
  end

  # ==========================================================================
  # Document-order successor / predecessor within `root`'s inclusive subtree.
  # ==========================================================================

  # The node after `id` in document order (first child, else next sibling, else the
  # nearest ancestor's next sibling), staying within `root`; nil at the end.
  @doc false
  def following_in(nodes, root, id) do
    case NodesTable.children(nodes, id) do
      [first | _] -> first
      [] -> next_skipping_up(nodes, root, id)
    end
  end

  defp next_skipping_up(_nodes, root, root), do: nil

  defp next_skipping_up(nodes, root, id) do
    case next_sibling(nodes, id) do
      nil ->
        parent = NodesTable.parent(nodes, id)
        if parent == nil or id == root, do: nil, else: next_skipping_up(nodes, root, parent)

      sibling ->
        sibling
    end
  end

  # The node before `id` in document order (previous sibling's deepest last descendant,
  # else the parent), staying within `root`; nil at root.
  @doc false
  def preceding_in(nodes, root, id) do
    if id == root do
      nil
    else
      case prev_sibling(nodes, id) do
        nil -> NodesTable.parent(nodes, id)
        sibling -> deepest_last(nodes, sibling)
      end
    end
  end

  defp deepest_last(nodes, id) do
    case NodesTable.children(nodes, id) do
      [] -> id
      children -> deepest_last(nodes, List.last(children))
    end
  end

  # ==========================================================================
  # Sibling helpers.
  # ==========================================================================

  @doc false
  def next_sibling(nodes, id), do: sibling(nodes, id, :next)
  @doc false
  def prev_sibling(nodes, id), do: sibling(nodes, id, :prev)

  defp sibling(nodes, id, direction) do
    parent = NodesTable.parent(nodes, id)

    if parent do
      siblings = NodesTable.children(nodes, parent)
      index = Enum.find_index(siblings, &(&1 == id))
      sibling_at(siblings, index, direction)
    end
  end

  defp sibling_at(siblings, index, :next), do: Enum.at(siblings, index + 1)
  defp sibling_at(_siblings, 0, :prev), do: nil
  defp sibling_at(siblings, index, :prev), do: Enum.at(siblings, index - 1)
end
