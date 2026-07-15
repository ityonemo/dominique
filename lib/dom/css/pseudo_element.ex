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

  # A pseudo-element matches nothing through the DOM query APIs — it represents a
  # generated rendering box, not an element, so querySelectorAll and matches/2
  # never return or match it. This holds for functional ones too: `::slotted(sel)`
  # is meaningful only in a shadow-tree stylesheet; shadowRoot.querySelectorAll(
  # "::slotted(...)") and el.matches("::slotted(...)") both yield nothing in
  # Chromium and Firefox (verified against the oracle). It still must PARSE (S5a)
  # so the selector is valid rather than raising.
  @impl DOM.CSS
  def match(_selector, _context, _protoset), do: %{}

  defimpl String.Chars do
    alias DOM.CSS.Serialize

    def to_string(%{name: name, arg: nil}), do: "::" <> Serialize.escape_ident(name)

    def to_string(%{name: name, arg: {:selector_list, list}}) do
      "::" <> Serialize.escape_ident(name) <> "(" <> Serialize.selector_list(list) <> ")"
    end
  end
end
