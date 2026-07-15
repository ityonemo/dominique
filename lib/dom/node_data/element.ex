defmodule DOM.NodeData.Element do
  @moduledoc "ETS record for an element node."

  use DOM.NodeData
  use DOM.HTML
  alias DOM.NodeData.NodesTable

  # `@enforce_keys` from DOM.NodeData is `[:root, :start, :stop]` (the nested-set extent:
  # `root` is the tree root's id, `{start, stop}` the binary order-keys containing all
  # descendants — this IS the child adjacency; see DOM.NodeData.NodesTable). `:local_name` is
  # enforced too. `content`/`shadow_root`/`definition`/`checked`/`parent` default nil.
  @enforce_keys @enforce_keys ++ [:local_name]
  defstruct @enforce_keys ++
              [
                :content,
                :shadow_root,
                :definition,
                :checked,
                :parent,
                manual_assigned: [],
                indeterminate: false,
                namespace: :html,
                attributes: []
              ]

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
          indeterminate: boolean(),
          parent: reference() | nil,
          attributes: [{attr_key(), String.t()}],
          root: reference(),
          start: binary(),
          stop: binary()
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
      child_ids = NodesTable.children_by_extent(nodes, node_id)
      [start_tag, DOM.HTML.children(name, child_ids, nodes), "</", name | ">"]
    end
  end
end
