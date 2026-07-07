defmodule DOM.Node.Element do
  @moduledoc """
  A handle to an element node. Elements may contain children and expose a
  `local_name`.
  """

  alias DOM.NodeData

  @enforce_keys [:server, :id]
  defstruct [:server, :id]

  use DOM.Node

  @type t :: %__MODULE__{server: GenServer.server(), id: reference()}

  @spec create(DOM.Node.Document.t(), String.t()) :: t()
  @spec local_name(t()) :: String.t()
  @spec get_attribute(t(), String.t()) :: String.t() | nil
  @spec set_attribute(t(), String.t(), String.t()) :: :ok
  @spec has_attribute(t(), String.t()) :: boolean()
  @spec remove_attribute(t(), String.t()) :: :ok
  @spec get_attribute_names(t()) :: [String.t()]
  @spec get_elements_by_tag_name(t(), String.t()) :: [t()]
  @spec get_elements_by_class_name(t(), String.t()) :: [t()]
  @spec query_selector(t(), String.t()) :: t() | nil
  @spec query_selector_all(t(), String.t()) :: [t()]
  @spec matches(t(), String.t()) :: boolean()

  def create(document, local_name) do
    DOM._create(document, %NodeData{type: __MODULE__, local_name: local_name})
  end

  def local_name(element), do: DOM._element_local_name(element.server, element.id)

  def get_attribute(element, name) do
    DOM._element_get_attribute(element.server, element.id, name)
  end

  def set_attribute(element, name, value) do
    DOM._element_set_attribute(element.server, element.id, name, value)
  end

  def has_attribute(element, name) do
    DOM._element_has_attribute(element.server, element.id, name)
  end

  def remove_attribute(element, name) do
    DOM._element_remove_attribute(element.server, element.id, name)
  end

  def get_attribute_names(element) do
    DOM._element_get_attribute_names(element.server, element.id)
  end

  def get_elements_by_tag_name(element, name) do
    GenServer.call(element.server, {:get_elements_by_tag_name, element.id, name})
  end

  def get_elements_by_class_name(element, names) do
    GenServer.call(element.server, {:get_elements_by_class_name, element.id, names})
  end

  def query_selector(element, selector) do
    DOM._query_selector(element.server, element.id, selector)
  end

  def query_selector_all(element, selector) do
    DOM._query_selector_all(element.server, element.id, selector)
  end

  def matches(element, selector) do
    DOM._matches(element.server, element.id, selector)
  end

  @impl DOM.Node
  def append_child(_element, %DOM.Node.Document{}), do: raise(DOM.HierarchyRequestError)

  def append_child(_element, %DOM.Node.DocumentType{}), do: raise(DOM.HierarchyRequestError)

  def append_child(element, child), do: DOM._node_append_child(element.server, element.id, child)

  @impl DOM.Node
  def insert_before(_element, %DOM.Node.Document{}, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  def insert_before(_element, %DOM.Node.DocumentType{}, _reference_child) do
    raise DOM.HierarchyRequestError
  end

  def insert_before(element, child, reference_child) do
    DOM._node_insert_before(element.server, element.id, child, reference_child)
  end

  @impl DOM.Node
  def child_nodes(element), do: DOM._node_child_nodes(element.server, element.id)

  @impl DOM.Node
  def parent_node(element), do: DOM._node_parent_node(element.server, element.id)

  @impl DOM.Node
  def value(element), do: DOM._node_value(element.server, element.id)

  @impl DOM.Node
  def node_type(_element), do: 1

  @impl DOM.Node
  def node_name(element), do: local_name(element)

  @impl DOM.Node
  def text_content(element), do: DOM._node_text_content(element.server, element.id)
end
