defmodule DOM.Element do
  @moduledoc """
  Element-intrinsic operations — the `local_name` and the attribute API. Each
  takes a `DOM.Node` handle and is guarded on `type: :element`, so calling one on
  a non-element handle fails fast. Tree queries (`get_elements_by_tag_name`,
  `query_selector`, `matches`, …), which accept any node as their scope, live on
  `DOM`; generic node operations live on `DOM.Node`.
  """

  alias DOM.Node

  @doc "The element's local name, or `nil` for a non-element node."
  @spec local_name(Node.t()) :: String.t() | nil
  def local_name(%Node{type: :element} = element) do
    DOM._element_local_name(element.server, element.id)
  end

  def local_name(%Node{}), do: nil

  @doc "The value of an attribute, or `nil` when absent."
  @spec get_attribute(Node.t(), String.t()) :: String.t() | nil
  def get_attribute(%Node{type: :element} = element, name) do
    DOM._element_get_attribute(element.server, element.id, name)
  end

  @doc "Sets an attribute value."
  @spec set_attribute(Node.t(), String.t(), String.t()) :: :ok
  def set_attribute(%Node{type: :element} = element, name, value) do
    DOM._element_set_attribute(element.server, element.id, name, value)
  end

  @doc "Whether the element carries an attribute."
  @spec has_attribute(Node.t(), String.t()) :: boolean()
  def has_attribute(%Node{type: :element} = element, name) do
    DOM._element_has_attribute(element.server, element.id, name)
  end

  @doc "Removes an attribute (a no-op when absent)."
  @spec remove_attribute(Node.t(), String.t()) :: :ok
  def remove_attribute(%Node{type: :element} = element, name) do
    DOM._element_remove_attribute(element.server, element.id, name)
  end

  @doc "The element's attribute names, in insertion order."
  @spec get_attribute_names(Node.t()) :: [String.t()]
  def get_attribute_names(%Node{type: :element} = element) do
    DOM._element_get_attribute_names(element.server, element.id)
  end
end
