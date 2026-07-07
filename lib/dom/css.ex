defmodule DOM.CSS do
  @moduledoc """
  Parses CSS selectors into a structured AST and serializes them back.

  `DOM.CSS` is the context module for CSS selectors. `parse/1` turns a selector
  string into an AST; `to_string/1` renders an AST back to a canonical selector
  string. The parser is generated at compile time by Pegasus from
  `lib/dom/css/selector.peg`, with semantic actions (below) building the AST in a
  single pass.

  ## AST

  `parse/1` returns a **selector list**: a list of complex selectors. A complex
  selector with no combinator collapses to its single compound; otherwise it is a
  list alternating compounds and combinators, e.g.
  `[compound_a, :child, compound_b]`. Combinators are `:descendant`, `:child`,
  `:next_sibling`, `:subsequent_sibling`.

  A compound is `{:compound, [simple]}` where each simple selector is one of:

    * `{:type, name}` — a type selector such as `div`
    * `:universal` — the `*` selector
    * `{:id, name}` — an `#id` selector
    * `{:class, name}` — a `.class` selector
    * `{:attr, name}` — an attribute presence selector `[a]`
    * `{:attr, name, op, value}` — `[a op v]`, op one of `:eq`, `:includes`,
      `:dash`, `:prefix`, `:suffix`, `:substring`
    * `{:attr, name, op, value, flag}` — with a case flag `:i` or `:s`
    * `{:pseudo_class, name}` — a keyword pseudo-class such as `:first-child`
    * `{:pseudo_class, "nth-child", {a, b}}` — a `:nth-*` selector, An+B as `{a, b}`
    * `{:not, selector_list}` — a `:not(...)` negation
    * `{:pseudo_element, name}` — a `::pseudo-element`

  """

  require Pegasus

  Pegasus.parser_from_file(Path.join(__DIR__, "css/selector.peg"),
    selector_list: [parser: :parse_selector, post_traverse: :selector_list],
    comma: [ignore: true],
    complex: [tag: true, post_traverse: :complex],
    combinator: [post_traverse: :combinator],
    descendant: [token: :descendant],
    ws: [ignore: true],
    compound: [tag: true, post_traverse: :compound],
    universal: [token: :universal],
    id: [post_traverse: :id],
    class: [post_traverse: :class],
    type: [post_traverse: :type],
    pseudo_element: [post_traverse: :pseudo_element],
    pseudo_class: [post_traverse: :pseudo_class],
    negation: [tag: true, post_traverse: :negation],
    selector_list_inner: [tag: true],
    nth: [tag: true, post_traverse: :nth],
    nth_name: [collect: true],
    anb: [collect: true, post_traverse: :anb],
    attribute: [tag: true, post_traverse: :attribute],
    attr_op: [collect: true, post_traverse: :attr_op],
    attr_value: [tag: true, post_traverse: :attr_value],
    attr_string: [collect: true, post_traverse: :attr_string],
    attr_flag: [collect: true, post_traverse: :attr_flag],
    name: [collect: true]
  )

  # ==========================================================================
  # API
  # ==========================================================================

  @type name :: String.t()
  @type attr_op :: :eq | :includes | :dash | :prefix | :suffix | :substring
  @type combinator :: :descendant | :child | :next_sibling | :subsequent_sibling

  @type simple ::
          {:type, name()}
          | :universal
          | {:id, name()}
          | {:class, name()}
          | {:attr, name()}
          | {:attr, name(), attr_op(), String.t()}
          | {:attr, name(), attr_op(), String.t(), :i | :s}
          | {:pseudo_class, name()}
          | {:pseudo_class, name(), {integer(), integer()}}
          | {:not, t()}
          | {:pseudo_element, name()}

  @type compound :: {:compound, [simple()]}
  @type complex :: compound() | [compound() | combinator()]
  @type t :: [complex()]

  @doc """
  Parses a CSS selector string into its AST.

  Raises `ArgumentError` when the selector is not valid.
  """
  @spec parse(String.t()) :: t()
  def parse(selector) do
    case parse_selector(selector) do
      {:ok, [ast], "", _context, _loc, _offset} ->
        ast

      {:ok, _ast, rest, _context, _loc, _offset} ->
        raise ArgumentError,
              "invalid CSS selector #{inspect(selector)} (unparsed: #{inspect(rest)})"

      {:error, reason, _rest, _context, _loc, _offset} ->
        raise ArgumentError, "invalid CSS selector #{inspect(selector)}: #{reason}"
    end
  end

  # ==========================================================================
  # Semantic actions
  # ==========================================================================

  # Args arrive as a reversed stack; reverse back to source order.

  defp selector_list(rest, complexes, context, _loc, _col) do
    {rest, [Enum.reverse(complexes)], context}
  end

  # A complex selector with no combinator collapses to its single compound;
  # otherwise it stays a list of alternating compounds and combinators.
  defp complex(rest, [{:complex, [compound]}], context, _loc, _col) do
    {rest, [compound], context}
  end

  defp complex(rest, [{:complex, parts}], context, _loc, _col) do
    {rest, [parts], context}
  end

  @combinators %{">" => :child, "+" => :next_sibling, "~" => :subsequent_sibling}

  defp combinator(rest, [:descendant], context, _loc, _col) do
    {rest, [:descendant], context}
  end

  defp combinator(rest, [delimiter], context, _loc, _col) do
    {rest, [Map.fetch!(@combinators, delimiter)], context}
  end

  defp compound(rest, [{:compound, simples}], context, _loc, _col) do
    {rest, [{:compound, simples}], context}
  end

  defp id(rest, [name, "#"], context, _loc, _col) do
    {rest, [{:id, name}], context}
  end

  defp class(rest, [name, "."], context, _loc, _col) do
    {rest, [{:class, name}], context}
  end

  defp type(rest, [name], context, _loc, _col) do
    {rest, [{:type, name}], context}
  end

  @attr_ops %{
    "=" => :eq,
    "~=" => :includes,
    "|=" => :dash,
    "^=" => :prefix,
    "$=" => :suffix,
    "*=" => :substring
  }

  defp attr_op(rest, [op], context, _loc, _col) do
    {rest, [{:op, Map.fetch!(@attr_ops, op)}], context}
  end

  defp attr_string(rest, [quoted], context, _loc, _col) do
    {rest, [String.slice(quoted, 1..-2//1)], context}
  end

  defp attr_value(rest, [{:attr_value, [value]}], context, _loc, _col) do
    {rest, [{:value, value}], context}
  end

  defp attr_flag(rest, [flag], context, _loc, _col) do
    {rest, [{:flag, String.to_atom(String.trim(flag))}], context}
  end

  defp attribute(rest, [{:attribute, parts}], context, _loc, _col) do
    {rest, [build_attribute(parts)], context}
  end

  defp build_attribute(["[", name, "]"]), do: {:attr, name}
  defp build_attribute(["[", name, {:op, op}, {:value, value}, "]"]), do: {:attr, name, op, value}

  defp build_attribute(["[", name, {:op, op}, {:value, value}, {:flag, flag}, "]"]) do
    {:attr, name, op, value, flag}
  end

  defp pseudo_element(rest, [name, "::"], context, _loc, _col) do
    {rest, [{:pseudo_element, name}], context}
  end

  defp pseudo_class(rest, [name, ":"], context, _loc, _col) do
    {rest, [{:pseudo_class, name}], context}
  end

  defp nth(rest, [{:nth, [":", name, "(", {a, b}, ")"]}], context, _loc, _col) do
    {rest, [{:pseudo_class, name, {a, b}}], context}
  end

  defp negation(
         rest,
         [{:negation, [":not(", {:selector_list_inner, list}, ")"]}],
         ctx,
         _loc,
         _col
       ) do
    {rest, [{:not, list}], ctx}
  end

  # An+B micro-syntax -> {a, b}. Whitespace inside the expression is already
  # stripped (ws is ignored) except within the collected text, so normalize it.
  defp anb(rest, [text], context, _loc, _col) do
    {rest, [parse_anb(text)], context}
  end

  defp parse_anb("odd"), do: {2, 1}
  defp parse_anb("even"), do: {2, 0}

  defp parse_anb(text) do
    text = String.replace(text, " ", "")

    case String.split(text, "n", parts: 2) do
      [b] -> {0, String.to_integer(b)}
      [coeff, rest] -> {anb_coeff(coeff), anb_b(rest)}
    end
  end

  defp anb_coeff(""), do: 1
  defp anb_coeff("-"), do: -1
  defp anb_coeff("+"), do: 1
  defp anb_coeff(n), do: String.to_integer(n)

  defp anb_b(""), do: 0
  defp anb_b(rest), do: String.to_integer(rest)
end
