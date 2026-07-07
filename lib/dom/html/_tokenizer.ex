defmodule DOM.HTML.Tokenizer do
  @moduledoc false

  # The HTML tokenizer, generated at compile time by Pegasus from
  # lib/dom/html/tokens.peg. The post_traverse handlers build DOM.HTML.Token.*
  # structs in a single pass. Public entry is DOM.HTML.tokenize/1, which delegates
  # here. Tokenization only -- no tree construction, no error recovery; character
  # references are left undecoded.

  require Pegasus

  alias DOM.HTML.Token

  Pegasus.parser_from_file(Path.join(__DIR__, "tokens.peg"),
    tokens: [parser: :parse_tokens, post_traverse: :tokens],
    token: [],
    comment: [tag: true, post_traverse: :comment],
    comment_data: [collect: true],
    doctype: [tag: true, post_traverse: :doctype],
    doctype_keyword: [ignore: true],
    doctype_ws: [ignore: true],
    doctype_name: [collect: true],
    doctype_rest: [ignore: true],
    start_tag: [tag: true, post_traverse: :start_tag],
    end_tag: [tag: true, post_traverse: :end_tag],
    self_closing: [token: :self_closing],
    tag_name: [collect: true, post_traverse: :tag_name],
    attributes: [tag: true, post_traverse: :attributes],
    attribute: [tag: true, post_traverse: :attribute],
    attr_name: [collect: true, post_traverse: :attr_name],
    attr_value: [tag: true, post_traverse: :attr_value],
    dq_value: [collect: true],
    sq_value: [collect: true],
    uq_value: [collect: true],
    ws: [ignore: true],
    character: [collect: true, post_traverse: :character]
  )

  @spec tokenize(String.t()) :: [struct()]
  def tokenize(html) do
    case parse_tokens(html) do
      {:ok, tokens, "", _context, _loc, _offset} ->
        tokens

      {:ok, _tokens, rest, _context, _loc, _offset} ->
        raise ArgumentError, "could not tokenize HTML (unparsed: #{inspect(rest)})"

      {:error, reason, _rest, _context, _loc, _offset} ->
        raise ArgumentError, "could not tokenize HTML: #{reason}"
    end
  end

  # ==========================================================================
  # Semantic actions (build token structs from each rule's captured args)
  # ==========================================================================

  # The top rule leaves the built tokens on the stack in document order.
  defp tokens(rest, tokens, context, _loc, _col) do
    {rest, tokens, context}
  end

  defp comment(rest, [{:comment, ["<!--", data, "-->"]}], context, _loc, _col) do
    {rest, [%Token.Comment{data: data}], context}
  end

  defp doctype(rest, [{:doctype, ["<!", name, ">"]}], context, _loc, _col) do
    {rest, [%Token.Doctype{name: String.downcase(name)}], context}
  end

  defp start_tag(rest, [{:start_tag, args}], context, _loc, _col) do
    name =
      Enum.find_value(args, fn
        {:tag_name, n} -> n
        _ -> nil
      end)

    attributes =
      Enum.find_value(args, fn
        {:attributes, a} -> a
        _ -> nil
      end)

    self_closing = :self_closing in args
    token = %Token.StartTag{name: name, attributes: attributes, self_closing: self_closing}
    {rest, [token], context}
  end

  defp end_tag(rest, [{:end_tag, args}], context, _loc, _col) do
    name =
      Enum.find_value(args, fn
        {:tag_name, n} -> n
        _ -> nil
      end)

    {rest, [%Token.EndTag{name: name}], context}
  end

  defp tag_name(rest, [name], context, _loc, _col) do
    {rest, [{:tag_name, String.downcase(name)}], context}
  end

  defp attributes(rest, [{:attributes, attributes}], context, _loc, _col) do
    {rest, [{:attributes, attributes}], context}
  end

  defp attribute(rest, [{:attribute, [{:attr_name, name}]}], context, _loc, _col) do
    {rest, [{name, ""}], context}
  end

  defp attribute(
         rest,
         [{:attribute, [{:attr_name, name}, "=", {:attr_value, value}]}],
         ctx,
         _l,
         _c
       ) do
    {rest, [{name, value}], ctx}
  end

  defp attr_name(rest, [name], context, _loc, _col) do
    {rest, [{:attr_name, String.downcase(name)}], context}
  end

  # Attribute values arrive with their quotes still attached (or bare, unquoted).
  defp attr_value(rest, [{:attr_value, [value]}], context, _loc, _col) do
    {rest, [{:attr_value, unquote_value(value)}], context}
  end

  defp character(rest, [data], context, _loc, _col) do
    {rest, [%Token.Character{data: data}], context}
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp unquote_value(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_value(<<?', rest::binary>>), do: String.trim_trailing(rest, "'")
  defp unquote_value(value), do: value
end
