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

  # Right-to-left: the last compound is the subject; candidates that match it are
  # kept only when the leftward combinator chain is satisfiable from that node.
  @impl DOM.CSS
  def match(%{parts: parts}, context, candidate_ids) do
    [subject | leftward] = Enum.reverse(parts)

    subject
    |> DOM.CSS.match(context, candidate_ids)
    |> Enum.filter(&chain?(leftward, &1, context))
  end

  # leftward is [combinator, compound, combinator, compound, ...] read right to
  # left. For each pair, the node must have a related node (per combinator) that
  # the compound matches and from which the remaining chain also holds.
  defp chain?([], _node_id, _context), do: true

  defp chain?([combinator, compound | rest], node_id, context) do
    context
    |> related(combinator, node_id)
    |> Enum.any?(fn related_id ->
      DOM.CSS.match(compound, context, [related_id]) != [] and chain?(rest, related_id, context)
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
