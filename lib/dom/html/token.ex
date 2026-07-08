use Protoss

defprotocol DOM.HTML.Token do
  @moduledoc """
  An HTML token produced by the tokenizer (`StartTag`, `EndTag`, `Character`,
  `Comment`, `Doctype`). The protocol callback `decode/1` resolves character
  references in a token's text (`Character` data, attribute values); non-text
  tokens return themselves. The tokenizer leaves references undecoded — apply
  decoding with `Enum.map(tokens, &DOM.HTML.Token.decode/1)`.

  The `after` block holds the tokenizer itself: `tokenize/1`, generated at compile
  time by Pegasus from `lib/dom/html/tokens.peg`. Tokenization only — no tree
  construction, no error recovery.
  """

  @doc "Resolves character references in a token's text; other tokens are unchanged."
  def decode(token)
after
  require Pegasus

  alias DOM.HTML.Token

  # Track the grammar as a compile dependency so editing tokens.peg alone
  # triggers regeneration (Pegasus.parser_from_file does not register it).
  @external_resource Path.join(__DIR__, "tokens.peg")

  # noscript is NOT a tokenizer rawtext element for us: we model the scripting-
  # DISABLED parser, where <noscript> content is ordinary markup.
  @raw_names ~w(script style textarea title xmp iframe noembed noframes)

  # title/noframes are RCDATA in HTML but ORDINARY elements in SVG/MathML foreign
  # content; their `raw_X` rule uses the :raw_rcdata post_traverse, which rejects
  # (backtracks to a normal start tag) when the context's foreign depth is > 0.
  # The rest are raw-text in every context and use :raw_element.
  @rcdata_in_foreign ~w(title noframes)

  raw_rules =
    Enum.flat_map(@raw_names, fn name ->
      handler = if name in @rcdata_in_foreign, do: :raw_rcdata, else: :raw_element

      [
        {:"raw_#{name}", tag: true, post_traverse: handler},
        {:"raw_open_#{name}", tag: true, post_traverse: :raw_open},
        {:"raw_name_#{name}", token: {:raw_name, name}},
        {:"raw_text_#{name}", tag: true, post_traverse: :raw_text},
        # raw_end_X is a transparent wrapper: raw_close_X / !. (EOF). When it
        # matches the close it forwards raw_close_X's EndTag; at EOF it adds
        # nothing.
        {:"raw_end_#{name}", []},
        {:"raw_close_#{name}", tag: true, post_traverse: :raw_close}
      ]
    end)

  Pegasus.parser_from_file(
    Path.join(__DIR__, "tokens.peg"),
    [
      tokens: [parser: :parse_tokens, post_traverse: :tokens],
      token: [],
      raw_element: [],
      # <plaintext> has no close/text pair — it consumes the rest of input.
      raw_plaintext: [tag: true, post_traverse: :raw_element],
      raw_open_plaintext: [tag: true, post_traverse: :raw_open],
      raw_name_plaintext: [token: {:raw_name, "plaintext"}],
      plaintext_body: [tag: true, post_traverse: :raw_text],
      # script-data escape sub-states: plain rules whose matched codepoints flow
      # up into raw_text_script's character collection.
      script_segment: [],
      script_escape: [],
      script_escaped_body: [],
      script_escaped_item: [],
      script_double_escape: [],
      script_dbl_open: [],
      script_dbl_body: [],
      script_dbl_end: [],
      script_dbl_close: [],
      script_tag_term: [],
      script_kw: [],
      raw_tag_end: [ignore: true]
    ] ++
      raw_rules ++
      [
        comment: [tag: true, post_traverse: :comment],
        comment_abrupt: [ignore: true],
        comment_normal: [],
        comment_data: [tag: true, post_traverse: :codepoints],
        comment_close: [ignore: true],
        bogus_comment: [tag: true, post_traverse: :bogus_comment],
        bogus_body: [tag: true, post_traverse: :bogus_data],
        bogus_end: [ignore: true],
        malformed_tag: [tag: true, post_traverse: :malformed_tag],
        doctype: [tag: true, post_traverse: :doctype],
        doctype_keyword: [ignore: true],
        doctype_name: [tag: true, post_traverse: :doctype_name],
        doctype_end: [ignore: true],
        doctype_junk: [ignore: true],
        doctype_public: [tag: true, post_traverse: :doctype_public],
        doctype_system: [tag: true, post_traverse: :doctype_system],
        public_kw: [ignore: true],
        system_kw: [ignore: true],
        doctype_str: [tag: true, post_traverse: :doctype_str],
        start_tag: [tag: true, post_traverse: :start_tag],
        end_tag: [tag: true, post_traverse: :end_tag],
        eof_tag: [tag: true, post_traverse: :eof_tag],
        self_closing: [token: :self_closing],
        tag_name: [collect: true, post_traverse: :tag_name],
        attributes: [tag: true, post_traverse: :attributes],
        attr_sep: [ignore: true],
        ws1: [ignore: true],
        stray_slash: [ignore: true],
        attribute: [tag: true, post_traverse: :attribute],
        attr_name: [collect: true, post_traverse: :attr_name],
        attr_value: [tag: true, post_traverse: :attr_value],
        dq_value: [collect: true],
        sq_value: [collect: true],
        uq_value: [collect: true],
        ws: [ignore: true],
        character: [post_traverse: :character]
      ]
  )

  @spec tokenize(String.t()) :: [struct()]
  def tokenize(html) do
    html |> normalize_newlines() |> tokenize_from()
  end

  # Tokenize, tolerating an unconsumed tail: the grammar covers the well-formed
  # and known-malformed forms, but for any residual stray byte (e.g. a lone `<`
  # at EOF) we emit that byte as character data and retry the remainder rather
  # than aborting the whole parse. A hard PEG error is still a real bug and raises.
  defp tokenize_from(""), do: []

  defp tokenize_from(html) do
    case parse_tokens(html) do
      {:ok, tokens, "", _context, _loc, _offset} ->
        tokens

      {:ok, tokens, rest, _context, _loc, _offset} ->
        <<stray::utf8, tail::binary>> = rest
        tokens ++ [struct!(Token.Character, data: <<stray::utf8>>)] ++ tokenize_from(tail)

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

  # The three sub-tokens (start tag, character interior, end tag) accumulate on
  # the stack in reverse; restore document order.
  defp raw_element(rest, [{_tag, tokens}], context, _loc, _col) do
    {rest, Enum.reverse(tokens), context}
  end

  # An RCDATA element (title/noframes) that is also an ordinary element in foreign
  # content: inside SVG/MathML (foreign depth > 0) REJECT the raw-text match so the
  # ordered choice falls through to `start_tag`, letting the tree builder treat the
  # interior as markup. Outside foreign content it behaves like raw_element.
  defp raw_rcdata(_rest, _tokens, %{foreign: depth}, _loc, _col) when depth > 0 do
    {:error, "rcdata element is ordinary in foreign content"}
  end

  defp raw_rcdata(rest, [{_tag, tokens}], context, _loc, _col) do
    {rest, Enum.reverse(tokens), context}
  end

  defp raw_open(rest, [{_open, args}], context, _loc, _col) do
    attributes =
      Enum.find_value(args, [], fn
        {:attributes, a} -> a
        _ -> nil
      end)

    {rest, [struct!(Token.StartTag, name: find_raw_name(args), attributes: attributes)], context}
  end

  defp raw_text(rest, [{_tag, codepoints}], context, _loc, _col) do
    {rest, [struct!(Token.Character, data: to_string_utf8(codepoints))], context}
  end

  defp raw_close(rest, [{_close, args}], context, _loc, _col) do
    {rest, [struct!(Token.EndTag, name: find_raw_name(args))], context}
  end

  defp find_raw_name(args) do
    Enum.find_value(args, fn
      {:raw_name, n} -> n
      _ -> nil
    end)
  end

  # Reassemble a `.`-matched codepoint list into a UTF-8 string (used by rules
  # like comment_data whose result is consumed by another handler).
  defp codepoints(rest, [{_tag, cps}], context, _loc, _col) do
    {rest, [to_string_utf8(cps)], context}
  end

  # Normal comment carries its data; an abrupt-close comment (`<!-->`/`<!--->`)
  # has no data arg.
  defp comment(rest, [{:comment, ["<!--", data]}], context, _loc, _col) do
    {rest, [struct!(Token.Comment, data: data)], context}
  end

  defp comment(rest, [{:comment, ["<!--"]}], context, _loc, _col) do
    {rest, [struct!(Token.Comment, data: "")], context}
  end

  # The bogus-comment body is tagged {:bogus_data, str} so it is unambiguous even
  # when empty (the marker literals '<'/'<!'/'</' are separate string args). `<?`
  # keeps its `?` because the `?` was matched by bogus_body, not the marker.
  defp bogus_data(rest, [{:bogus_body, cps}], context, _loc, _col) do
    {rest, [{:bogus_data, to_string_utf8(cps)}], context}
  end

  defp bogus_comment(rest, [{:bogus_comment, args}], context, _loc, _col) do
    data =
      Enum.find_value(args, "", fn
        {:bogus_data, s} -> s
        _ -> nil
      end)

    {rest, [struct!(Token.Comment, data: data)], context}
  end

  # `<>` is literal text; `</>` and a bare `</` recover with no token / as text.
  defp malformed_tag(rest, [{:malformed_tag, ["<>"]}], context, _loc, _col),
    do: {rest, [struct!(Token.Character, data: "<>")], context}

  defp malformed_tag(rest, [{:malformed_tag, ["</"]}], context, _loc, _col),
    do: {rest, [struct!(Token.Character, data: "</")], context}

  defp malformed_tag(rest, [{:malformed_tag, ["</>"]}], context, _loc, _col),
    do: {rest, [], context}

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

    token = struct!(Token.Doctype, name: name, public_id: public_id, system_id: system_id)
    {rest, [token], context}
  end

  defp doctype_name(rest, [{:doctype_name, cps}], context, _loc, _col) do
    {rest, [{:doctype_name, cps |> to_string_utf8() |> String.downcase()}], context}
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

  # The captured string is the opening quote + content + an optional matching
  # close quote (missing when the id ran into `>`/EOF). Strip the leading quote
  # and a trailing quote if present.
  defp doctype_str(rest, [{:doctype_str, cps}], context, _loc, _col) do
    {rest, [strip_quotes(to_string_utf8(cps))], context}
  end

  defp strip_quotes(<<q, rest::binary>>) when q in [?", ?'] do
    String.trim_trailing(rest, <<q>>)
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

    token =
      struct!(Token.StartTag, name: name, attributes: attributes, self_closing: self_closing)

    {rest, [token], enter_foreign(context, name, self_closing)}
  end

  defp end_tag(rest, [{:end_tag, args}], context, _loc, _col) do
    name =
      Enum.find_value(args, fn
        {:tag_name, n} -> n
        _ -> nil
      end)

    {rest, [struct!(Token.EndTag, name: name)], leave_foreign(context, name)}
  end

  # WHATWG "eof-in-tag": a tag that ran to end-of-input without its `>` is dropped.
  defp eof_tag(rest, [{:eof_tag, _args}], context, _loc, _col), do: {rest, [], context}

  # A foreign-content depth counter threaded through the parse context. Entering
  # <svg>/<math> (not self-closed) increments it; the matching end tag decrements.
  # It lets the RCDATA raw-text rules (e.g. <title>) know they are inside foreign
  # content, where those elements are ORDINARY (their content is markup, not raw
  # text) — see raw_rcdata/5. The `foreignObject`/`annotation-xml` HTML-integration
  # points are not modeled here; nested HTML inside them keeps the outer depth.
  defp enter_foreign(context, name, false) when name in ~w(svg math) do
    Map.update(context, :foreign, 1, &(&1 + 1))
  end

  defp enter_foreign(context, _name, _self_closing), do: context

  defp leave_foreign(context, name) when name in ~w(svg math) do
    Map.update(context, :foreign, 0, &max(&1 - 1, 0))
  end

  defp leave_foreign(context, _name), do: context

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

  defp character(rest, codepoints, context, _loc, _col) do
    {rest, [struct!(Token.Character, data: to_string_utf8(Enum.reverse(codepoints)))], context}
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # `.` matches UTF-8 codepoints; reassemble with List.to_string (NOT
  # IO.iodata_to_binary, which would mis-encode multibyte chars as raw bytes).
  defp to_string_utf8(codepoints), do: List.to_string(codepoints)

  defp unquote_value(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_value(<<?', rest::binary>>), do: String.trim_trailing(rest, "'")
  defp unquote_value(value), do: value

  # WHATWG input preprocessing: CRLF and lone CR both normalize to LF.
  defp normalize_newlines(html) do
    html |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
  end
end
