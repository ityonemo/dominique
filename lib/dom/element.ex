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
  alias DOM.NodeData.Table

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
  @spec attach_shadow(Node.t(), :open | :closed) :: Node.t()
  def attach_shadow(%Node{type: :element} = element, mode) when mode in [:open, :closed] do
    DOM._element_attach_shadow(element.server, element.node_id, mode)
  end

  @doc """
  The element's shadow root, or `nil` — including `nil` for a **closed** shadow
  root (the closed root is reachable only via `attach_shadow/2`'s return value).
  """
  @spec shadow_root(Node.t()) :: Node.t() | nil
  def shadow_root(%Node{type: :element} = element), do: DOM._element_shadow_root(element)
  def shadow_root(%Node{}), do: nil

  @doc "The value of an attribute, or `nil` when absent."
  @spec get_attribute(Node.t(), String.t()) :: String.t() | nil
  def get_attribute(%Node{type: :element} = element, name) do
    case List.keyfind(attributes(element), name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  @doc "Whether the element carries an attribute."
  @spec has_attribute(Node.t(), String.t()) :: boolean()
  def has_attribute(%Node{type: :element} = element, name) do
    List.keymember?(attributes(element), name, 0)
  end

  @doc "The element's attribute names, in insertion order."
  @spec get_attribute_names(Node.t()) :: [String.t()]
  def get_attribute_names(%Node{type: :element} = element) do
    Enum.map(attributes(element), fn {name, _value} -> name end)
  end

  @doc "Sets an attribute value."
  @spec set_attribute(Node.t(), String.t(), String.t()) :: :ok
  def set_attribute(%Node{type: :element} = element, name, value) do
    update_attributes(element, &List.keystore(&1, name, 0, {name, value}))
  end

  @doc "Removes an attribute (a no-op when absent)."
  @spec remove_attribute(Node.t(), String.t()) :: :ok
  def remove_attribute(%Node{type: :element} = element, name) do
    update_attributes(element, &List.keydelete(&1, name, 0))
  end

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

  # The element's raw attribute list, read straight from the record.
  defp attributes(%Node{} = element) do
    [attributes] = DOM._select_nodes(element.server, attributes_spec(element.node_id))
    attributes
  end

  # Atomically reads the record, applies `fun` to its attribute list, and writes
  # the updated record back — a single server hop so no operation interleaves.
  defp update_attributes(%Node{node_id: node_id} = element, fun) do
    DOM._atomic_ets_op(element.server, fn nodes, index ->
      [{^node_id, record}] = :ets.lookup(nodes, node_id)
      updated = %{record | attributes: fun.(record.attributes)}
      :ets.insert(nodes, {node_id, updated})
      Table.index_put(index, node_id, updated)
      # A slot= (light child) or name= (a <slot>) change re-slots — recompute the
      # affected shadow host's assignment.
      if host = DOM.NodeData.Slots.affected_host(nodes, node_id) do
        DOM.NodeData.Slots.recompute(nodes, index, host)
      end

      :ok
    end)
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
