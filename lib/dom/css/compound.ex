defmodule DOM.CSS.Compound do
  @moduledoc "A compound selector: a run of simple selectors with no combinator."

  defstruct simples: []

  use DOM.CSS

  @type t :: %__MODULE__{simples: [DOM.CSS.simple()]}

  @impl DOM.CSS
  def match(%{simples: simples}, context, candidate_ids) do
    Enum.reduce(simples, candidate_ids, fn simple, candidates ->
      DOM.CSS.match(simple, context, candidates)
    end)
  end

  defimpl String.Chars do
    def to_string(%{simples: simples}), do: Enum.map_join(simples, &Kernel.to_string/1)
  end
end
