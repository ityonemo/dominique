defmodule DOM.CSS.Complex do
  @moduledoc """
  A complex selector: compounds joined by combinators, e.g.
  `[compound_a, :child, compound_b]`. A relative complex (inside `:has`) may lead
  with a combinator. Combinators are the atoms `:descendant`, `:child`,
  `:next_sibling`, `:subsequent_sibling`.
  """

  alias DOM.CSS.Query

  defstruct parts: []

  use DOM.CSS

  @type t :: %__MODULE__{parts: [DOM.CSS.Compound.t() | DOM.CSS.combinator()]}

  # Right-to-left: the last compound is the subject; the leftward combinator chain must be
  # satisfiable from each subject match. Two strategies:
  #   * FAST (same-tree): resolve each leftward compound over the whole scope by index lookup,
  #     then answer the combinator by an extent-containment / parent / sibling join — no
  #     per-candidate re-query (kills the N+1). Used when the query can't cross a shadow boundary.
  #   * WALK (shadow-crossing): the per-candidate ancestor/sibling walk via `related`, which
  #     crosses shadow boundaries (`:host p`). The containment model is per-tree, so it can't
  #     express host→shadow nesting; this path preserves it.
  @impl DOM.CSS
  def match(%{parts: parts}, context, protoset) do
    [subject | leftward] = Enum.reverse(parts)
    subject_ps = DOM.CSS.match(subject, context, protoset)

    if shadow_crossing?(context) do
      Query.filter_protoset(subject_ps, &chain?(leftward, &1, context))
    else
      chain_fast(leftward, subject_ps, context)
    end
  end

  # A query crosses a shadow boundary only when it is scoped INSIDE a shadow tree (its
  # `:host`/host lives in the light tree, a different extent root) — exactly `scope_host != nil`.
  # A plain light-tree query never reaches shadow content (it isn't in the candidate set).
  defp shadow_crossing?(%{scope_host: host}), do: host != nil

  # FAST path: fold the leftward [combinator, compound, ...] chain, re-seating the protoset at
  # each step to be keyed by the newly-matched (left) element, value = the subject leaf_ref.
  # Returns a protoset keyed by the leftmost compound's matches; `query_ids` reads its values.
  defp chain_fast([], protoset, _context), do: protoset

  defp chain_fast([:descendant, compound | rest], subject_ps, context) do
    left_ps = DOM.CSS.match(compound, context, Query.seed(context.scope_candidates))
    subject_ext = Query.resolve_extents(context, subject_ps)
    left_ext = Query.resolve_extents(context, left_ps)
    next_ps = Query.resolve_descendants(left_ext, subject_ext, :current)
    chain_fast(rest, next_ps, context)
  end

  # Combinators not yet on the fast path (:child, siblings — Phases 4/5): fall back to the
  # per-candidate walk for the remaining chain from here. Keyed by the current protoset's
  # keys, values preserved.
  defp chain_fast([_combinator | _] = remaining, protoset, context) do
    Query.filter_protoset(protoset, &chain?(remaining, &1, context))
  end

  # leftward is [combinator, compound, combinator, compound, ...] read right to
  # left. For each pair, the node must have a related node (per combinator) that
  # the compound matches and from which the remaining chain also holds.
  defp chain?([], _node_id, _context), do: true

  defp chain?([combinator, compound | rest], node_id, context) do
    context
    |> related(combinator, node_id)
    |> Enum.any?(fn related_id ->
      DOM.CSS.match(compound, context, Query.seed([related_id])) != %{} and
        chain?(rest, related_id, context)
    end)
  end

  # :child / :descendant cross the shadow boundary: the parent of a shadow root's
  # child is (for selector purposes) the host, so `:host > p` and `:host p` match
  # the shadow tree.
  defp related(%{nodes: nodes}, :child, node_id) do
    case Query.shadow_parent(nodes, node_id) do
      nil -> []
      parent_id -> [parent_id]
    end
  end

  defp related(%{nodes: nodes}, :descendant, node_id), do: Query.shadow_ancestors(nodes, node_id)

  defp related(context, :next_sibling, node_id) do
    context |> Query.prev_element_siblings(node_id) |> Enum.take(1)
  end

  defp related(context, :subsequent_sibling, node_id) do
    Query.prev_element_siblings(context, node_id)
  end

  defimpl String.Chars do
    # A leading combinator (relative selector) renders without a leading space.
    def to_string(%{parts: [combinator | rest]})
        when is_atom(combinator) and combinator != :descendant do
      String.trim_leading(part(combinator)) <> Enum.map_join(rest, &part/1)
    end

    def to_string(%{parts: parts}), do: Enum.map_join(parts, &part/1)

    defp part(:descendant), do: " "
    defp part(:child), do: " > "
    defp part(:next_sibling), do: " + "
    defp part(:subsequent_sibling), do: " ~ "
    defp part(compound), do: Kernel.to_string(compound)
  end
end
