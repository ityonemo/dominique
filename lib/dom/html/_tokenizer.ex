defmodule DOM.HTML.Tokenizer do
  @moduledoc false

  # The HTML tokenizer, generated at compile time by Pegasus from
  # lib/dom/html/tokens.peg. The post_traverse handlers build DOM.HTML.Token.*
  # structs in a single pass. Public entry is DOM.HTML.tokenize/1, which delegates
  # here. Tokenization only -- no tree construction, no error recovery; character
  # references are left undecoded.

  require Pegasus

  alias DOM.HTML.Token

  # Track the grammar as a compile dependency so editing tokens.peg alone
  # triggers regeneration (Pegasus.parser_from_file does not register it).
  @external_resource Path.join(__DIR__, "tokens.peg")

  Pegasus.parser_from_file(Path.join(__DIR__, "tokens.peg"),
    tokens: [parser: :parse_tokens, post_traverse: :tokens],
    token: [],
    comment: [tag: true, post_traverse: :comment],
    comment_data: [collect: true],
    doctype: [tag: true, post_traverse: :doctype],
    doctype_keyword: [ignore: true],
    doctype_ws: [ignore: true],
    doctype_name: [collect: true, post_traverse: :doctype_name],
    doctype_public: [tag: true, post_traverse: :doctype_public],
    doctype_system: [tag: true, post_traverse: :doctype_system],
    public_kw: [ignore: true],
    system_kw: [ignore: true],
    doctype_str: [collect: true, post_traverse: :doctype_str],
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
    case html |> normalize_newlines() |> parse_tokens() do
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

  defp doctype(rest, [{:doctype, args}], context, _loc, _col) do
    name =
      Enum.find_value(args, fn
        {:doctype_name, n} -> n
        _ -> nil
      end)

    public_id =
      Enum.find_value(args, fn
        {:public_id, id} -> id
        _ -> nil
      end)

    system_id =
      Enum.find_value(args, fn
        {:system_id, id} -> id
        _ -> nil
      end)

    token = %Token.Doctype{name: name, public_id: public_id, system_id: system_id}
    {rest, [token], context}
  end

  defp doctype_name(rest, [name], context, _loc, _col) do
    {rest, [{:doctype_name, String.downcase(name)}], context}
  end

  # PUBLIC "pub" "sys"?  -> a public id and optionally a system id.
  defp doctype_public(rest, [{:doctype_public, [public]}], context, _loc, _col) do
    {rest, [{:public_id, public}], context}
  end

  defp doctype_public(rest, [{:doctype_public, [public, system]}], context, _loc, _col) do
    {rest, [{:system_id, system}, {:public_id, public}], context}
  end

  defp doctype_system(rest, [{:doctype_system, [system]}], context, _loc, _col) do
    {rest, [{:system_id, system}], context}
  end

  defp doctype_str(rest, [str], context, _loc, _col) do
    {rest, [String.slice(str, 1..-2//1)], context}
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

  # WHATWG input preprocessing: CRLF and lone CR both normalize to LF.
  defp normalize_newlines(html) do
    html |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
  end
end
