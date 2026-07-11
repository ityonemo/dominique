defmodule DOM.CSS.PseudoElement do
  @moduledoc """
  A pseudo-element such as `::before`, or a functional one like `::slotted(sel)`
  whose `arg` is `{:selector_list, list}`.
  """

  alias DOM.CSS.Serialize

  @enforce_keys [:name]
  defstruct [:name, arg: nil]

  use DOM.CSS

  @type arg :: nil | {:selector_list, [DOM.CSS.complex()]}
  @type t :: %__MODULE__{name: String.t(), arg: arg()}

  # A pseudo-element never matches an element node (functional ones like
  # ::slotted are overridden in later phases).
  @impl DOM.CSS
  def match(_selector, _context, _candidate_ids), do: []

  defimpl String.Chars do
    alias DOM.CSS.Serialize

    def to_string(%{name: name, arg: nil}), do: "::" <> Serialize.escape_ident(name)

    def to_string(%{name: name, arg: {:selector_list, list}}) do
      "::" <> Serialize.escape_ident(name) <> "(" <> Serialize.selector_list(list) <> ")"
    end
  end
end
