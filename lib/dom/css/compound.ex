defmodule DOM.CSS.Compound do
  @moduledoc "A compound selector: a run of simple selectors with no combinator."

  defstruct simples: []

  use DOM.CSS

  @type t :: %__MODULE__{simples: [DOM.CSS.simple()]}

  @impl DOM.CSS
  def match(_selector, _nodes, _candidate_ids), do: raise("unimplemented")

  defimpl String.Chars do
    def to_string(%{simples: simples}), do: Enum.map_join(simples, &Kernel.to_string/1)
  end
end
