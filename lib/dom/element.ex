defmodule DOM.Element do
  @moduledoc """
  Element-intrinsic operations — the `local_name` and the attribute API. Each
  takes a `DOM.Node` handle and is guarded on `type: :element`, so calling one on
  a non-element handle fails fast. Tree queries (`get_elements_by_tag_name`,
  `query_selector`, `matches`, …), which accept any node as their scope, live on
  `DOM`; generic node operations live on `DOM.Node`.
  """

  use MatchSpec

  alias DOM.Node
  alias DOM.NodeData.Element
  alias DOM.NodeData.IndexTable

  @doc "The element's local name, or `nil` for a non-element node."
  @spec local_name(Node.t()) :: String.t() | nil
  def local_name(%Node{type: :element} = element) do
    [local_name] = DOM._select_nodes(element.server, local_name_spec(element.node_id))
    local_name
  end

  defmatchspecp local_name_spec(node_id) do
    {^node_id, %{__struct__: Element, local_name: local_name}} -> local_name
  end

  def local_name(%Node{}), do: nil

  @doc "The element's namespace (`:html | :svg | :mathml`), or `nil` for a non-element."
  @spec namespace(Node.t()) :: DOM.NodeData.Element.namespace() | nil
  def namespace(%Node{type: :element} = element) do
    [namespace] = DOM._select_nodes(element.server, namespace_spec(element.node_id))
    namespace
  end

  defmatchspecp namespace_spec(node_id) do
    {^node_id, %{__struct__: Element, namespace: namespace}} -> namespace
  end

  def namespace(%Node{}), do: nil

  @doc "A template element's content DocumentFragment, or `nil` for others."
  @spec content(Node.t()) :: Node.t() | nil
  def content(%Node{type: :element} = element), do: DOM._element_content(element)
  def content(%Node{}), do: nil

  @doc """
  Attach a shadow root to the element and return its handle. `mode` is `:open` or
  `:closed`. Raises `DOM.NotSupportedError` if the element already has a shadow
  root or is not a valid shadow host.
  """
  @spec attach_shadow(Node.t(), :open | :closed, keyword()) :: Node.t()
  def attach_shadow(%Node{type: :element} = element, mode, opts \\ [])
      when mode in [:open, :closed] do
    slot_assignment = Keyword.get(opts, :slot_assignment, :named)
    DOM._element_attach_shadow(element.server, element.node_id, mode, slot_assignment)
  end

  @doc """
  The element's shadow root, or `nil` — including `nil` for a **closed** shadow
  root (the closed root is reachable only via `attach_shadow/2`'s return value).
  """
  @spec shadow_root(Node.t()) :: Node.t() | nil
  def shadow_root(%Node{type: :element} = element), do: DOM._element_shadow_root(element)
  def shadow_root(%Node{}), do: nil

  @doc "The value of an attribute (by qualified name), or `nil` when absent."
  @spec get_attribute(Node.t(), String.t()) :: String.t() | nil
  def get_attribute(%Node{type: :element} = element, name) do
    # The first attribute whose key satisfies the qualified-name lookup (a plain
    # string key by equality, or a namespaced triple whose qualified form matches).
    case Enum.find(attributes(element), fn {key, _v} -> Element.matches_key?(key, name) end) do
      {_key, value} -> value
      nil -> nil
    end
  end

  @doc "Whether the element carries an attribute (by qualified name)."
  @spec has_attribute(Node.t(), String.t()) :: boolean()
  def has_attribute(%Node{type: :element} = element, name) do
    Enum.any?(attributes(element), fn {key, _v} -> Element.matches_key?(key, name) end)
  end

  @doc "The element's attribute qualified names, in insertion order."
  @spec get_attribute_names(Node.t()) :: [String.t()]
  def get_attribute_names(%Node{type: :element} = element) do
    Enum.map(attributes(element), fn {key, _value} -> Element.qualified_name(key) end)
  end

  @doc """
  Sets an attribute value by qualified name. If an attribute with that qualified
  name exists (plain OR namespaced), its value is updated in place (its key —
  including any namespace — is preserved); otherwise a new plain-keyed attribute is
  appended. (setAttribute does not parse namespaces; use set_attribute_ns for that.)
  """
  @spec set_attribute(Node.t(), String.t(), String.t()) :: :ok
  def set_attribute(%Node{type: :element} = element, name, value) do
    update_attributes(element, &put_by_qualified_name(&1, name, value), name)
  end

  @doc "Removes an attribute by qualified name (a no-op when absent)."
  @spec remove_attribute(Node.t(), String.t()) :: :ok
  def remove_attribute(%Node{type: :element} = element, name) do
    update_attributes(
      element,
      fn attrs -> Enum.reject(attrs, fn {key, _v} -> Element.matches_key?(key, name) end) end,
      name
    )
  end

  # The plain-string-keyed value for `name` in an attribute list, or nil.
  defp attr_value(attrs, name) do
    case Enum.find(attrs, fn {key, _v} -> key == name end) do
      {_key, value} -> value
      nil -> nil
    end
  end

  # Update the value of the attribute whose key matches `name` (preserving that
  # key), or append a plain-string-keyed attribute when none matches.
  defp put_by_qualified_name(attrs, name, value) do
    if Enum.any?(attrs, fn {key, _v} -> Element.matches_key?(key, name) end) do
      Enum.map(attrs, &update_matching_value(&1, name, value))
    else
      attrs ++ [{name, value}]
    end
  end

  defp update_matching_value({key, _v} = attr, name, value) do
    if Element.matches_key?(key, name), do: {key, value}, else: attr
  end

  @doc """
  The value of the attribute with namespace `url` and local name `local`, or `nil`.
  `url` may be `nil` to select a null-namespace (plain) attribute.
  """
  @spec get_attribute_ns(Node.t(), String.t() | nil, String.t()) :: String.t() | nil
  def get_attribute_ns(%Node{type: :element} = element, url, local) do
    case Enum.find(attributes(element), &ns_key_matches?(&1, url, local)) do
      {_key, value} -> value
      nil -> nil
    end
  end

  @doc """
  Sets a namespaced attribute. `qualified_name` is split into `prefix:local`;
  identity is `(url, local)` — an existing attribute with the same namespace + local
  is updated in place (its prefix is preserved, per the spec), otherwise a new
  `{prefix, local, url}` attribute is appended. A `nil`/empty `url` stores a plain
  (null-namespace) attribute keyed by `qualified_name`.
  """
  @spec set_attribute_ns(Node.t(), String.t() | nil, String.t(), String.t()) :: :ok
  def set_attribute_ns(%Node{type: :element} = element, url, qualified_name, value)
      when url in [nil, ""] do
    set_attribute(element, qualified_name, value)
  end

  def set_attribute_ns(%Node{type: :element} = element, url, qualified_name, value) do
    {prefix, local} = DOM.Namespace.split_qname(qualified_name)

    update_attributes(element, &put_ns_attr(&1, url, prefix, local, value))
  end

  # Overwrite the (url, local) attribute's value (key/prefix preserved), or append a
  # fresh {prefix, local, url} attribute when none matches.
  defp put_ns_attr(attrs, url, prefix, local, value) do
    if Enum.any?(attrs, &ns_key_matches?(&1, url, local)) do
      Enum.map(attrs, &update_ns_value(&1, url, local, value))
    else
      attrs ++ [{{prefix, local, url}, value}]
    end
  end

  defp update_ns_value(attr, url, local, value) do
    if ns_key_matches?(attr, url, local), do: put_elem(attr, 1, value), else: attr
  end

  # Whether an attribute matches the namespace identity (url, local).
  defp ns_key_matches?({{_prefix, local, url}, _value}, url, local), do: true
  defp ns_key_matches?({name, _value}, nil, local) when is_binary(name), do: name == local
  defp ns_key_matches?(_attr, _url, _local), do: false

  @doc """
  The namespace url declared for `prefix` in scope, or `nil`. In an HTML document
  there are no XML namespace declarations, so this resolves to `nil` (matching the
  browsers).
  """
  @spec lookup_namespace_uri(Node.t(), String.t() | nil) :: String.t() | nil
  def lookup_namespace_uri(%Node{type: :element}, _prefix), do: nil

  @doc """
  A prefix bound to namespace `url` in scope, or `nil`. As with
  `lookup_namespace_uri`, HTML documents carry no XML declarations, so `nil`.
  """
  @spec lookup_prefix(Node.t(), String.t() | nil) :: String.t() | nil
  def lookup_prefix(%Node{type: :element}, _url), do: nil

  @doc """
  Toggles `name`: adds it (value `""`) when absent, removes it when present.
  `force: true` only ever adds, `force: false` only ever removes. Returns whether
  the attribute is present afterward.
  """
  @spec toggle_attribute(Node.t(), String.t(), boolean() | nil) :: boolean()
  def toggle_attribute(%Node{type: :element} = element, name, force \\ nil) do
    present = has_attribute(element, name)
    # add when force is true, or (force nil and currently absent); else remove.
    add? = if is_nil(force), do: not present, else: force

    if add?, do: set_attribute(element, name, ""), else: remove_attribute(element, name)
    add?
  end

  @doc "The nearest inclusive ancestor of `element` matching `selector`, or `nil`."
  @spec closest(Node.t(), String.t()) :: Node.t() | nil
  def closest(%Node{type: :element} = element, selector) do
    if DOM.matches(element, selector) do
      element
    else
      case Node.parent_node(element) do
        %Node{type: :element} = parent -> closest(parent, selector)
        _ -> nil
      end
    end
  end

  @doc "Descendant elements of `element` with the given tag name (scoped query)."
  @spec get_elements_by_tag_name(Node.t(), String.t()) :: [Node.t()]
  def get_elements_by_tag_name(%Node{type: :element} = element, name),
    do: DOM.get_elements_by_tag_name(element, name)

  @doc """
  Parses `html` and inserts the result relative to `element`, at `position`:
  `"beforebegin"` / `"afterend"` (as siblings) or `"afterbegin"` / `"beforeend"`
  (as first/last children).
  """
  @spec insert_adjacent_html(Node.t(), String.t(), String.t()) :: :ok
  def insert_adjacent_html(%Node{type: :element} = element, position, html) do
    DOM._element_insert_adjacent_html(element.server, element.node_id, position, html)
  end

  @doc "Inserts `node` relative to `element` at `position` (see insert_adjacent_html), returning `node`."
  @spec insert_adjacent_element(Node.t(), String.t(), Node.t()) :: Node.t()
  def insert_adjacent_element(%Node{type: :element} = element, position, %Node{} = node) do
    insert_adjacent_node(element, position, node)
    node
  end

  @doc "Inserts a Text node with `text` relative to `element` at `position`."
  @spec insert_adjacent_text(Node.t(), String.t(), String.t()) :: :ok
  def insert_adjacent_text(%Node{type: :element} = element, position, text) do
    document = Node.owner_document(element) || element
    insert_adjacent_node(element, position, DOM.create_text_node(document, text))
    :ok
  end

  # Insert an already-built node relative to `element` per the adjacency position.
  defp insert_adjacent_node(element, "beforebegin", node), do: Node.before(element, [node])
  defp insert_adjacent_node(element, "afterend", node), do: Node.after(element, [node])
  defp insert_adjacent_node(element, "afterbegin", node), do: Node.prepend(element, [node])
  defp insert_adjacent_node(element, "beforeend", node), do: Node.append(element, [node])

  @doc false
  # The element's raw attribute list `[{key, value}]` (key may be a namespaced
  # triple). Exposed for the html5lib .dat dumper, which renders the space form.
  @spec raw_attributes(Node.t()) :: [{Element.attr_key(), String.t()}]
  def raw_attributes(%Node{type: :element} = element), do: attributes(element)

  # The element's raw attribute list, read straight from the record.
  defp attributes(%Node{} = element) do
    [attributes] = DOM._select_nodes(element.server, attributes_spec(element.node_id))
    attributes
  end

  # Atomically reads the record, applies `fun` to its attribute list, and writes
  # the updated record back — a single server hop so no operation interleaves.
  # `changed_name` (a plain qualified name, or nil for the namespaced paths) is the
  # attribute the caller set/removed — passed so the custom-element attributeChanged
  # reaction can fire for exactly that name (it fires on every observed set, even to
  # the same value, unlike the MutationObserver record which only logs real changes).
  defp update_attributes(%Node{node_id: node_id} = element, fun, changed_name \\ nil) do
    DOM._atomic_ets_op(
      element.server,
      fn nodes, index ->
        [{^node_id, record}] = :ets.lookup(nodes, node_id)
        before = record.attributes
        after_attrs = fun.(before)
        updated = %{record | attributes: after_attrs}
        :ets.insert(nodes, {node_id, updated})
        IndexTable.index_put(index, node_id, updated)
        # A slot= (light child) or name= (a <slot>) change re-slots the affected
        # shadow host and signals slotchange on any slot whose assignment changed.
        DOM._recompute_slots(nodes, index, node_id)
        # MutationObserver: one attributes record per changed attribute name.
        DOM._queue_attribute_records(nodes, index, node_id, before, after_attrs)
        # Custom element: attributeChanged for the set/removed name (if observed).
        if changed_name do
          DOM._custom_element_attribute_changed(
            nodes,
            index,
            node_id,
            changed_name,
            attr_value(before, changed_name),
            attr_value(after_attrs, changed_name)
          )
        end

        :ok
      end,
      :mutates
    )
  end

  defmatchspecp attributes_spec(node_id) do
    {^node_id, %{__struct__: Element, attributes: attributes}} -> attributes
  end

  @doc "The element's serialized descendants (its `innerHTML`)."
  @spec inner_html(Node.t()) :: String.t()
  def inner_html(%Node{type: :element} = element) do
    DOM._element_inner_html(element.server, element.node_id)
  end

  @doc """
  Set the element's `innerHTML`: fragment-parse `html` using the element as the
  parsing context, then replace the element's children with the result.
  """
  @spec set_inner_html(Node.t(), String.t()) :: :ok
  def set_inner_html(%Node{type: :element} = element, html) do
    DOM._element_set_inner_html(element.server, element.node_id, html)
  end

  @doc "The element and its subtree serialized (its `outerHTML`)."
  @spec outer_html(Node.t()) :: String.t()
  def outer_html(%Node{type: :element} = element) do
    DOM._element_outer_html(element.server, element.node_id)
  end

  @doc """
  Set the element's `outerHTML`: fragment-parse `html` using the element's PARENT
  as the parsing context, then replace the element itself with the result. Raises
  `DOM.NoModificationAllowedError` when the element has no parent.
  """
  @spec set_outer_html(Node.t(), String.t()) :: :ok
  def set_outer_html(%Node{type: :element} = element, html) do
    DOM._element_set_outer_html(element.server, element.node_id, html)
  end
end
