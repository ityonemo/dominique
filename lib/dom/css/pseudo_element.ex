defmodule DOM.CSS.PseudoElement do
  @moduledoc "A pseudo-element such as `::before`."

  alias DOM.CSS.Serialize

  @enforce_keys [:name]
  defstruct [:name]

  use DOM.CSS

  @type t :: %__MODULE__{name: String.t()}

  # A pseudo-element never matches an element node.
  @impl DOM.CSS
  def match(_selector, _context, _candidate_ids), do: []

  defimpl String.Chars do
    def to_string(%{name: name}), do: "::" <> Serialize.escape_ident(name)
  end
end
