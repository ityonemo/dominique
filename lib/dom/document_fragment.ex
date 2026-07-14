defmodule DOM.DocumentFragment do
  @moduledoc """
  Operations on a document-fragment handle (`%DOM.Node{type: :document_fragment}`).
  A fragment is a detached, parentless container built with the generic `DOM.Node`
  mutators; this module adds the `ParentNode` query surface (`querySelector` /
  `querySelectorAll`) scoped to the fragment's subtree. (A `ShadowRoot` is a fragment
  subtype but has its own scope module, `DOM.ShadowRoot`.)
  """

  alias DOM.Node

  @doc "The first descendant of `fragment` matching `selector`, or `nil`."
  @spec query_selector(Node.t(), String.t()) :: Node.t() | nil
  def query_selector(%Node{type: :document_fragment} = fragment, selector),
    do: DOM._query_selector(fragment, selector)

  @doc "All descendants of `fragment` matching `selector`, in document order."
  @spec query_selector_all(Node.t(), String.t()) :: [Node.t()]
  def query_selector_all(%Node{type: :document_fragment} = fragment, selector),
    do: DOM._query_selector_all(fragment, selector)
end
