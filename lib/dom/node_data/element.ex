defmodule DOM.NodeData.Element do
  @moduledoc "ETS record for an element node."

  @enforce_keys [:local_name]
  defstruct [
    :local_name,
    :content,
    # The element's shadow root id (a DOM.NodeData.ShadowRoot, a detached root
    # tree), or nil. Parallel to `content` (template contents); the serializer
    # never reads it, so the shadow tree is invisible to the host's outerHTML.
    :shadow_root,
    # The custom-element definition (a DOM.CustomElementDefinition) once this element
    # is UPGRADED, else nil. Stored on the element — not just a registry lookup — so it
    # RIDES the element across cross-document adoption (the browser: an upgraded element
    # retains its definition). `nil` = undefined; a later `define` upgrades only nil
    # elements. `:defined` = a built-in name OR definition != nil.
    definition: nil,
    # Manually-assigned node ids for a `<slot>` in a manual-slot-assignment shadow
    # root (the ordered arguments of slot.assign()); [] otherwise. Only meaningful on
    # a `<slot>` element. The effective assignment filters these to host children.
    manual_assigned: [],
    # Checkedness OVERRIDE for an input (WHATWG checkedness + dirty flag, compressed):
    # nil = "clean" — use the `checked` ATTRIBUTE as the default; true/false = "dirty" —
    # user-toggled checkedness (a click activation), the attribute no longer drives it.
    # :checked reads the override if set, else the attribute.
    checked: nil,
    namespace: :html,
    parent: nil,
    attributes: [],
    # Nested-set extent: `root` is the tree root's id; `{start, stop}` are binary
    # order-keys containing all descendants' extents. This IS the child adjacency —
    # a node's ordered children are the rows whose `parent` is it, by `start` key
    # (DOM.NodeData.Table.children_by_extent/2). See DOM.NodeData.Table.
    root: nil,
    start: nil,
    stop: nil
  ]

  use DOM.NodeData
  use DOM.HTML

  @type namespace :: :html | :svg | :mathml

  # An attribute KEY is either a plain qualified-name string (the common case, keyed
  # by the whole string) or a namespaced `{prefix, local, url}` triple (prefix may be
  # nil for a bare `xmlns`). The VALUE is always a plain string. Identity of a
  # namespaced attribute is (url, local) — the prefix is not part of identity.
  @type attr_key :: String.t() | {String.t() | nil, String.t(), String.t()}

  @type t :: %__MODULE__{
          local_name: String.t(),
          namespace: namespace(),
          content: reference() | nil,
          shadow_root: reference() | nil,
          definition: DOM.CustomElementDefinition.t() | nil,
          manual_assigned: [reference()],
          checked: boolean() | nil,
          parent: reference() | nil,
          attributes: [{attr_key(), String.t()}],
          root: reference() | nil,
          start: binary() | nil,
          stop: binary() | nil
        }

  @doc "The DOM qualified name of an attribute key (`prefix:local`, or the bare name)."
  @spec qualified_name(attr_key()) :: String.t()
  def qualified_name(name) when is_binary(name), do: name
  def qualified_name({nil, local, _url}), do: local
  def qualified_name({prefix, local, _url}), do: prefix <> ":" <> local

  @doc """
  The html5lib .dat rendering of an attribute key: a namespaced triple renders its
  prefix and local space-separated (`xlink href`); a plain key renders verbatim.
  """
  @spec dat_name(attr_key()) :: String.t()
  def dat_name(name) when is_binary(name), do: name
  def dat_name({nil, local, _url}), do: local
  def dat_name({prefix, local, _url}), do: prefix <> " " <> local

  @doc """
  Whether a stored attribute `key` satisfies a plain qualified-name lookup for
  `qname` — a bare string matches by equality; a triple matches when its qualified
  form equals `qname`.
  """
  @spec matches_key?(attr_key(), String.t()) :: boolean()
  def matches_key?(name, qname) when is_binary(name), do: name == qname
  def matches_key?({_prefix, _local, _url} = key, qname), do: qualified_name(key) == qname

  @impl DOM.NodeData
  def type(_element), do: :element

  @impl DOM.NodeData
  def node_type(_element), do: 1

  @impl DOM.NodeData
  def node_name(%{local_name: local_name}), do: local_name

  @impl DOM.HTML
  def serialize(%__MODULE__{local_name: name} = element, node_id, nodes) do
    # Render each attribute KEY to its qualified-name string here (in the record
    # module, outside the DOM.HTML `after`-block cycle) before serializing.
    rendered = for {key, value} <- element.attributes, do: {qualified_name(key), value}
    start_tag = DOM.HTML.start_tag(name, rendered)

    if DOM.HTML.void?(name) do
      start_tag
    else
      child_ids = DOM.NodeData.Table.children_by_extent(nodes, node_id)
      [start_tag, DOM.HTML.children(name, child_ids, nodes), "</", name | ">"]
    end
  end
end
