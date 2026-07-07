defmodule DOM.CSS.PseudoClass do
  @moduledoc """
  A pseudo-class. The `arg` field carries the variant:

    * `nil` — a keyword pseudo-class, e.g. `:first-child`
    * `{a, b}` — an An+B `:nth-*` selector
    * `{a, b, selector_list}` — `:nth-*(An+B of S)`
    * `{:selector_list, list}` — `:not`/`:is`/`:where`/`:has(...)` (for `:has`,
      a relative complex in `list` may lead with a combinator)
    * `{:args, [ident]}` — `:lang`/`:dir(...)`
  """

  alias DOM.CSS.Serialize

  @enforce_keys [:name]
  defstruct [:name, arg: nil]

  use DOM.CSS

  @type arg ::
          nil
          | {integer(), integer()}
          | {integer(), integer(), [DOM.CSS.complex()]}
          | {:selector_list, [DOM.CSS.complex()]}
          | {:args, [String.t()]}

  @type t :: %__MODULE__{name: String.t(), arg: arg()}

  @impl DOM.CSS
  def match(_selector, _nodes, _candidate_ids), do: raise("unimplemented")

  defimpl String.Chars do
    def to_string(%{name: name, arg: nil}), do: ":" <> Serialize.escape_ident(name)

    def to_string(%{name: name, arg: {a, b}}) when is_integer(a) and is_integer(b) do
      ":" <> Serialize.escape_ident(name) <> "(" <> Serialize.anb(a, b) <> ")"
    end

    def to_string(%{name: name, arg: {a, b, list}}) when is_integer(a) and is_integer(b) do
      ":" <>
        Serialize.escape_ident(name) <>
        "(" <> Serialize.anb(a, b) <> " of " <> Serialize.selector_list(list) <> ")"
    end

    def to_string(%{name: name, arg: {:selector_list, list}}) do
      ":" <> Serialize.escape_ident(name) <> "(" <> Serialize.selector_list(list) <> ")"
    end

    def to_string(%{name: name, arg: {:args, args}}) do
      rendered = Enum.map_join(args, ", ", &Serialize.escape_ident/1)
      ":" <> Serialize.escape_ident(name) <> "(" <> rendered <> ")"
    end
  end
end
