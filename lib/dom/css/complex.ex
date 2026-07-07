defmodule DOM.CSS.Complex do
  @moduledoc """
  A complex selector: compounds joined by combinators, e.g.
  `[compound_a, :child, compound_b]`. A relative complex (inside `:has`) may lead
  with a combinator. Combinators are the atoms `:descendant`, `:child`,
  `:next_sibling`, `:subsequent_sibling`.
  """

  defstruct parts: []

  use DOM.CSS

  @type t :: %__MODULE__{parts: [DOM.CSS.Compound.t() | DOM.CSS.combinator()]}

  @impl DOM.CSS
  def match(_selector, _nodes, _candidate_ids), do: raise("unimplemented")

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
