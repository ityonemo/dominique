defmodule DOM.Namespace do
  @moduledoc false

  # The closed namespace universe Dominique models: the element-namespace atoms
  # (:html/:svg/:mathml) and the fixed attribute-prefix table (xlink/xml/xmlns) that
  # the HTML parser's foreign-content adjustment produces. Single source of truth
  # shared by the parser (building `{prefix, local, url}` attribute keys) and the DOM
  # namespace API (createElementNS / get/setAttributeNS / lookup*).

  @html "http://www.w3.org/1999/xhtml"
  @svg "http://www.w3.org/2000/svg"
  @mathml "http://www.w3.org/1998/Math/MathML"
  @xlink "http://www.w3.org/1999/xlink"
  @xml "http://www.w3.org/XML/1998/namespace"
  @xmlns "http://www.w3.org/2000/xmlns/"

  # Element-namespace atom <-> url.
  @element_uris %{html: @html, svg: @svg, mathml: @mathml}
  @element_atoms Map.new(@element_uris, fn {atom, url} -> {url, atom} end)

  # Attribute prefix -> url (the fixed foreign-attribute + reserved prefixes).
  @prefix_uris %{"xlink" => @xlink, "xml" => @xml, "xmlns" => @xmlns}
  @prefix_for %{@xlink => "xlink", @xml => "xml", @xmlns => "xmlns"}

  @doc "The url of an element-namespace atom (`:html`/`:svg`/`:mathml`)."
  @spec element_uri(atom()) :: String.t()
  def element_uri(atom), do: Map.fetch!(@element_uris, atom)

  @doc "The element-namespace atom for a url, or `nil` if not one of the three."
  @spec element_atom(String.t()) :: atom() | nil
  def element_atom(url), do: Map.get(@element_atoms, url)

  @doc "The url for a known attribute prefix (`xlink`/`xml`/`xmlns`), or `nil`."
  @spec uri_for_prefix(String.t() | nil) :: String.t() | nil
  def uri_for_prefix(prefix), do: Map.get(@prefix_uris, prefix)

  @doc "A known prefix for a url, or `nil` (the reserved xlink/xml/xmlns prefixes)."
  @spec prefix_for_uri(String.t()) :: String.t() | nil
  def prefix_for_uri(url), do: Map.get(@prefix_for, url)

  @doc "Split a qualified name into `{prefix, local}` (prefix `nil` when unprefixed)."
  @spec split_qname(String.t()) :: {String.t() | nil, String.t()}
  def split_qname(qname) do
    case String.split(qname, ":", parts: 2) do
      [local] -> {nil, local}
      [prefix, local] -> {prefix, local}
    end
  end

  @doc """
  Build an attribute KEY from a qualified name known to be namespaced with `url`:
  `{prefix, local, url}`. Used by the parser's foreign-attribute adjustment.
  """
  @spec attr_key(String.t(), String.t()) :: {String.t() | nil, String.t(), String.t()}
  def attr_key(qname, url) do
    {prefix, local} = split_qname(qname)
    {prefix, local, url}
  end

  # The known constants, exposed for callers that compare against them.
  def xlink, do: @xlink
  def xml, do: @xml
  def xmlns, do: @xmlns
  def html, do: @html
  def svg, do: @svg
  def mathml, do: @mathml
end
