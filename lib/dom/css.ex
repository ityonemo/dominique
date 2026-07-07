use Protoss

defprotocol DOM.CSS do
  @moduledoc """
  CSS selectors: parse a selector string into a struct AST, match it against a
  DOM, and serialize it back.

  `DOM.CSS` is a protocol whose callback `match/3` is implemented by each
  selector struct (`DOM.CSS.Type`, `DOM.CSS.Compound`, `DOM.CSS.Complex`, …).
  `parse/1` and `to_string/1` are shared entry points defined in the `after`
  block; the parser itself lives in `DOM.CSS.Parser` (kept apart so the struct
  modules that `use DOM.CSS` do not create a compile cycle).

  ## AST

  `parse/1` returns a **selector list**: a plain list of complex selectors. A
  complex selector with no combinator is a `DOM.CSS.Compound`; with combinators
  it is a `DOM.CSS.Complex` whose `parts` alternate compounds and combinator
  atoms (`:descendant`, `:child`, `:next_sibling`, `:subsequent_sibling`).

  A `DOM.CSS.Compound` holds `simples`, a list of simple selectors, each a
  struct: `DOM.CSS.Type`, `DOM.CSS.Universal`, `DOM.CSS.Id`, `DOM.CSS.Class`,
  `DOM.CSS.Attribute`, `DOM.CSS.PseudoClass`, or `DOM.CSS.PseudoElement`.
  """

  @type name :: String.t()
  @type attr_op :: :eq | :includes | :dash | :prefix | :suffix | :substring
  @type combinator :: :descendant | :child | :next_sibling | :subsequent_sibling
  @type namespace :: String.t() | :any | :none

  @type simple ::
          DOM.CSS.Type.t()
          | DOM.CSS.Universal.t()
          | DOM.CSS.Id.t()
          | DOM.CSS.Class.t()
          | DOM.CSS.Attribute.t()
          | DOM.CSS.PseudoClass.t()
          | DOM.CSS.PseudoElement.t()

  @type complex :: DOM.CSS.Compound.t() | DOM.CSS.Complex.t()
  @type t :: [complex()]

  @doc """
  Matches this selector against `nodes` (an ETS table of `DOM.NodeData`),
  reducing `candidate_ids` to the ids that match. Not yet implemented.
  """
  def match(selector, nodes, candidate_ids)
after
  @doc """
  Parses a CSS selector string into its struct AST.

  Raises `ArgumentError` when the selector is not valid.
  """
  @spec parse(String.t()) :: DOM.CSS.t()
  defdelegate parse(selector), to: DOM.CSS.Parser

  @doc """
  Serializes a selector AST back to a canonical selector string.

  `parse/1` and `to_string/1` round-trip: `parse(to_string(ast)) == ast`.
  """
  @spec to_string(DOM.CSS.t()) :: String.t()
  def to_string(selector_list), do: DOM.CSS.Serialize.selector_list(selector_list)
end
