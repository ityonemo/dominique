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

  @doc "The element's local name, or `nil` for a non-element node."
  @spec local_name(Node.t()) :: String.t() | nil
  def local_name(%Node{type: :element} = element) do
    [local_name] = DOM._select(element.server, local_name_spec(element.id))
    local_name
  end

  defmatchspecp local_name_spec(node_id) do
    {^node_id, %{__struct__: Element, local_name: local_name}} -> local_name
  end

  def local_name(%Node{}), do: nil

  @doc "The element's namespace (`:html | :svg | :mathml`), or `nil` for a non-element."
  @spec namespace(Node.t()) :: DOM.NodeData.Element.namespace() | nil
  def namespace(%Node{type: :element} = element) do
    [namespace] = DOM._select(element.server, namespace_spec(element.id))
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

  # The element's raw attribute list, read straight from the record.
  defp attributes(%Node{} = element) do
    [attributes] = DOM._select(element.server, attributes_spec(element.id))
    attributes
  end

  # Atomically reads the record, applies `fun` to its attribute list, and writes
  # the updated record back — a single server hop so no operation interleaves.
  defp update_attributes(%Node{id: node_id} = element, fun) do
    DOM._atomic_ets_op(element.server, fn nodes ->
      [{^node_id, record}] = :ets.lookup(nodes, node_id)
      :ets.insert(nodes, {node_id, %{record | attributes: fun.(record.attributes)}})
      :ok
    end)
  end

  defmatchspecp attributes_spec(node_id) do
    {^node_id, %{__struct__: Element, attributes: attributes}} -> attributes
  end

  @doc "The element's serialized descendants (its `innerHTML`)."
  @spec inner_html(Node.t()) :: String.t()
  def inner_html(%Node{type: :element} = element) do
    DOM._element_inner_html(element.server, element.id)
  end

  @doc "The element and its subtree serialized (its `outerHTML`)."
  @spec outer_html(Node.t()) :: String.t()
  def outer_html(%Node{type: :element} = element) do
    DOM._element_outer_html(element.server, element.id)
  end
end
