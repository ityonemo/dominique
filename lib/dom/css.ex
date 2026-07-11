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

  @typedoc """
  The tables a match runs against: `nodes` (the `DOM.NodeData` ETS table) and
  `index` (the id/class `:ordered_set` index). Threaded through `match/3` so leaf
  matchers can reach either — most only need `nodes`; `#id`/`.class` read `index`.
  """
  @type context :: %{
          nodes: :ets.tid(),
          index: :ets.tid(),
          scope_host: reference() | nil
        }

  @doc """
  Matches this selector against `context` (see `t:context/0`), reducing
  `candidate_ids` to the ids that match.
  """
  def match(selector, context, candidate_ids)
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

  @doc """
  Validates a parsed selector AST for a query context and returns it unchanged,
  or raises `ArgumentError`.

  A **string** namespace prefix (e.g. `svg|rect`) is a syntax error in a
  `querySelector`/`matches` context because no prefixes are declared there — the
  browser throws. `*|` (`:any`), bare (`nil`), and `|` (`:none`, the null
  namespace) are all valid and pass through.
  """
  @spec validate!(DOM.CSS.t()) :: DOM.CSS.t()
  def validate!(selector_list) do
    Enum.each(selector_list, &validate_node!/1)
    selector_list
  end

  # Walk the AST by shape (map keys), not by struct module, to avoid a
  # compile-time dependency on the per-selector modules that `use DOM.CSS`.
  defp validate_node!(combinator) when is_atom(combinator), do: :ok

  defp validate_node!(%{parts: parts}), do: Enum.each(parts, &validate_node!/1)
  defp validate_node!(%{simples: simples}), do: Enum.each(simples, &validate_node!/1)

  defp validate_node!(%{namespace: ns}) when is_binary(ns) do
    raise ArgumentError, "undeclared namespace prefix #{inspect(ns)} in selector"
  end

  defp validate_node!(%{arg: {:selector_list, list}}), do: Enum.each(list, &validate_node!/1)

  defp validate_node!(%{arg: {a, b, list}}) when is_integer(a) and is_integer(b) do
    Enum.each(list, &validate_node!/1)
  end

  defp validate_node!(_simple), do: :ok

  @doc """
  Binds the scoping root `scope_id` into every `:scope` pseudo-class in the
  parsed selector, so `match/3` can match it against candidates. Called by the
  query path once the concrete root id is known.
  """
  @spec bind_scope(DOM.CSS.t(), reference()) :: DOM.CSS.t()
  def bind_scope(selector_list, scope_id) do
    Enum.map(selector_list, &bind_node(&1, scope_id))
  end

  # Walk by map shape (as validate!) to avoid a compile-time cycle.
  defp bind_node(combinator, _scope_id) when is_atom(combinator), do: combinator

  defp bind_node(%{parts: parts} = node, scope_id) do
    %{node | parts: Enum.map(parts, &bind_node(&1, scope_id))}
  end

  defp bind_node(%{simples: simples} = node, scope_id) do
    %{node | simples: Enum.map(simples, &bind_node(&1, scope_id))}
  end

  defp bind_node(%{name: "scope", arg: nil} = node, scope_id) do
    %{node | arg: {:scope, scope_id}}
  end

  defp bind_node(%{arg: {:selector_list, list}} = node, scope_id) do
    %{node | arg: {:selector_list, bind_scope(list, scope_id)}}
  end

  defp bind_node(%{arg: {a, b, list}} = node, scope_id) when is_integer(a) and is_integer(b) do
    %{node | arg: {a, b, bind_scope(list, scope_id)}}
  end

  defp bind_node(node, _scope_id), do: node
end
