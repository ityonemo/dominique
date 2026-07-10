use Protoss

defprotocol DOM.HTML do
  @moduledoc """
  HTML fragment serialization (the WHATWG `outerHTML` / "serialize an element's
  children" algorithm), dispatched on the internal `DOM.NodeData.*` records. Each
  `serialize(node_data, nodes)` runs inside the DOM GenServer over the raw ETS
  `nodes` table and recurses into children by id. Backs
  `DOM.Element.inner_html/1` and `outer_html/1`.

  The `after` block holds the struct-agnostic string helpers the impls share
  (impls can't share private functions). Keeping it free of any `DOM.NodeData.*`
  reference avoids a compile deadlock with the structs that `use DOM.HTML`.
  """

  @doc """
  Serializes a node and its subtree (its `outerHTML`) as **iodata**. `node_id` is
  the node's own id, so container kinds can read their ordered children from the
  record extents (`DOM.NodeData.Table.children_by_extent/2`) rather than an inline
  field. The caller materializes it once with `IO.iodata_to_binary/1` at the
  GenServer boundary.
  """
  def serialize(node_data, node_id, nodes)
after
  @doc """
  Tokenizes an HTML string into a list of `DOM.HTML.Token.*` structs
  (`StartTag`, `EndTag`, `Character`, `Comment`, `Doctype`). Tokenization only —
  no tree construction. Character references are left undecoded; apply
  `Enum.map(tokens, &DOM.HTML.Token.decode/1)` to resolve them.
  """
  defdelegate tokenize(html), to: DOM.HTML.Token

  @doc "Tokenize `html` and decode character references — the decoded token list."
  def tokens(html) do
    html |> tokenize() |> Enum.map(&DOM.HTML.Token.decode/1)
  end

  @doc """
  Convenience: parse an HTML string into a `%DOM.Node{type: :document}` tree.
  Equivalent to `DOM.new(html)` — the tree is built (WHATWG tree construction)
  into the new document's table before it is returned.
  """
  def parse(html), do: DOM.new(html)

  # RCDATA (title/textarea) and RAWTEXT (style/script/…) fragment contexts: the
  # tokenizer starts in a text state, so the whole input is one character run.
  @fragment_rcdata ~w(title textarea)
  @fragment_rawtext ~w(style xmp iframe noembed noframes noscript script plaintext)

  @doc """
  The HTML fragment parsing algorithm (§13.4). Parses `html` as the contents of a
  `context` element and returns the synthetic `html` root whose children are the
  fragment nodes. `context` is the html5lib context string (e.g. `"div"`,
  `"svg path"`). Not yet wired into `inner_html`.
  """
  def parse_fragment(html, context) do
    parsed = parse_context(context)
    tokens = fragment_tokens(html, parsed.name)
    document_id = make_ref()
    {:ok, server} = DOM.start_link(document_id: document_id, fragment: {tokens, parsed})
    root_id = GenServer.call(server, :fragment_root)
    %DOM.Node{server: server, node_id: root_id, type: :element}
  end

  @doc """
  Tokenize `html` for a fragment context element named `name`. A raw-text/RCDATA
  context makes the whole input one text token: RCDATA (title/textarea) decodes
  character references, RAWTEXT/script data does not; any other context uses
  normal tokenization + decoding. Used by the inner_html setter.
  """
  def fragment_tokens(html, name) when name in @fragment_rcdata do
    [DOM.HTML.Token.decode(%DOM.HTML.Token.Character{data: html})]
  end

  def fragment_tokens(html, name) when name in @fragment_rawtext do
    [%DOM.HTML.Token.Character{data: html, decode?: false}]
  end

  def fragment_tokens(html, _name) do
    html |> tokenize() |> Enum.map(&DOM.HTML.Token.decode/1)
  end

  # The context string is "name" (HTML) or "svg name" / "math name" (foreign).
  defp parse_context("svg " <> name), do: %{name: name, namespace: :svg}
  defp parse_context("math " <> name), do: %{name: name, namespace: :mathml}
  defp parse_context(name), do: %{name: name, namespace: :html}

  # Void elements: a start tag with no children and no end tag.
  @void ~w(area base br col embed hr img input link meta source track wbr)

  # Raw-text elements: their text children are emitted verbatim, not escaped.
  @raw_text ~w(style script xmp iframe noembed noframes noscript plaintext)

  @doc "Whether `local_name` is a void element (no end tag)."
  def void?(local_name), do: local_name in @void

  @doc "A start tag `<name attr=\"v\"...>` as iodata."
  def start_tag(name, attributes), do: [?<, name, attributes(attributes) | ">"]

  @doc """
  An element's children (given its tag name, child ids, and the ETS table) as
  iodata. Text children of a raw-text element skip escaping.
  """
  def children(local_name, child_ids, nodes) do
    raw? = local_name in @raw_text
    Enum.map(child_ids, &child(&1, nodes, raw?))
  end

  # Text data: escape &, <, > and the non-breaking space. Returns iodata.
  def escape_text(value), do: escape(value, [?<, ?>])

  defp child(child_id, nodes, raw?) do
    [{^child_id, child_data}] = :ets.lookup(nodes, child_id)

    if raw? and is_struct(child_data, DOM.NodeData.Text) do
      child_data.value
    else
      DOM.HTML.serialize(child_data, child_id, nodes)
    end
  end

  defp attributes(attributes) do
    Enum.map(attributes, fn {name, value} ->
      [?\s, name, ~s(="), escape_attribute(value) | ~s(")]
    end)
  end

  # Attribute value: escape &, the double-quote delimiter, < and > (matching
  # browser serialization), plus the non-breaking space. Returns iodata.
  defp escape_attribute(value), do: escape(value, [?", ?<, ?>])

  # Splits `value` on &/nbsp (always escaped) plus the caller's `extra` chars,
  # emitting the entity for each and leaving the rest as binary chunks — so the
  # result is iodata that shares the original binary's unescaped runs.
  defp escape(value, extra), do: escape(value, [?&, 0xA0 | extra], value, 0, 0, [])

  defp escape(<<>>, _set, original, start, len, acc) do
    [acc | binary_part(original, start, len)]
  end

  defp escape(<<char::utf8, rest::binary>>, set, original, start, len, acc) do
    if char in set do
      chunk = binary_part(original, start, len)
      char_len = byte_size(<<char::utf8>>)
      escape(rest, set, original, start + len + char_len, 0, [acc, chunk | entity(char)])
    else
      escape(rest, set, original, start, len + byte_size(<<char::utf8>>), acc)
    end
  end

  defp entity(?&), do: "&amp;"
  defp entity(?<), do: "&lt;"
  defp entity(?>), do: "&gt;"
  defp entity(?"), do: "&quot;"
  defp entity(0xA0), do: "&nbsp;"
end
