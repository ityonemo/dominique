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

  @doc "Serializes a node and its subtree (its `outerHTML`)."
  def serialize(node_data, nodes)
after
  # Void elements: a start tag with no children and no end tag.
  @void ~w(area base br col embed hr img input link meta source track wbr)

  # Raw-text elements: their text children are emitted verbatim, not escaped.
  @raw_text ~w(style script xmp iframe noembed noframes noscript plaintext)

  @doc "Whether `local_name` is a void element (no end tag)."
  def void?(local_name), do: local_name in @void

  @doc "A start tag: `<name attr=\"v\"...>`."
  def start_tag(name, attributes), do: "<" <> name <> attributes(attributes) <> ">"

  @doc """
  Serializes an element's children (given its tag name, child ids, and the ETS
  table), concatenated. Text children of a raw-text element skip escaping.
  """
  def children(local_name, child_ids, nodes) do
    raw? = local_name in @raw_text
    Enum.map_join(child_ids, "", &child(&1, nodes, raw?))
  end

  # Text data: escape &, <, > and the non-breaking space.
  def escape_text(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\u{00A0}", "&nbsp;")
  end

  defp child(child_id, nodes, raw?) do
    [{^child_id, child_data}] = :ets.lookup(nodes, child_id)

    if raw? and is_struct(child_data, DOM.NodeData.Text) do
      child_data.value
    else
      DOM.HTML.serialize(child_data, nodes)
    end
  end

  defp attributes(attributes) do
    Enum.map_join(attributes, "", fn {name, value} ->
      ~s( #{name}="#{escape_attribute(value)}")
    end)
  end

  # Attribute value: escape &, the double-quote delimiter, < and > (matching
  # browser serialization), plus the non-breaking space.
  defp escape_attribute(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\u{00A0}", "&nbsp;")
  end
end
