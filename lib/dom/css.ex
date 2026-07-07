defmodule DOM.CSS do
  @moduledoc """
  Parses CSS selectors into a structured AST and serializes them back.

  `DOM.CSS` is the context module for CSS selectors. `parse/1` turns a selector
  string into an AST; `to_string/1` renders an AST back to a canonical selector
  string. The parser is generated at compile time by Pegasus from
  `lib/dom/css/selector.peg`, with semantic actions (below) building the AST in a
  single pass.

  ## AST

  A selector list is a list of compound selectors (combinators are added later).
  A compound is `{:compound, [simple]}` where each simple selector is one of:

    * `{:type, name}` — a type selector such as `div`
    * `:universal` — the `*` selector
    * `{:id, name}` — an `#id` selector
    * `{:class, name}` — a `.class` selector

  """

  require Pegasus

  Pegasus.parser_from_file(Path.join(__DIR__, "css/selector.peg"),
    selector_list: [parser: :parse_selector, post_traverse: :selector_list],
    compound: [tag: true, post_traverse: :compound],
    universal: [token: :universal],
    id: [post_traverse: :id],
    class: [post_traverse: :class],
    type: [post_traverse: :type],
    name: [collect: true]
  )

  # ==========================================================================
  # API
  # ==========================================================================

  @type name :: String.t()
  @type simple ::
          {:type, name()} | :universal | {:id, name()} | {:class, name()}
  @type compound :: {:compound, [simple()]}
  @type t :: [compound()]

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

  defp selector_list(rest, compounds, context, _loc, _col) do
    {rest, [Enum.reverse(compounds)], context}
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
end
