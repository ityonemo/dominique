use Protoss

defprotocol DOM.Node do
  @moduledoc """
  Shared operations implemented by every DOM node handle.
  """

  def append_child(node, child)
  def insert_before(node, child, reference_child)
  def child_nodes(node)
  def parent_node(node)
  def value(node)
after
  @doc """
  Removes `child` from `node` and returns it. Raises `DOM.NotFoundError` if
  `child` is not a child of `node`.

  Uniform across every node type, so it is defined once here rather than per
  implementation: removal dispatches on the parent, which always delegates to
  the owning server.
  """
  def remove_child(node, child) do
    DOM._node_remove_child(node.server, node.id, child)
  end

  @doc """
  Replaces `old_child` with `new_child` under `node` and returns `old_child`.

  Raises `DOM.NotFoundError` if `old_child` is not a child of `node`, and
  `DOM.HierarchyRequestError` if the replacement would be invalid. Like
  `remove_child/2`, it dispatches on the parent and is defined once here.
  """
  def replace_child(node, new_child, old_child) do
    DOM._node_replace_child(node.server, node.id, new_child, old_child)
  end

  @doc "Returns the node's first child, or `nil` when it has none."
  def first_child(node), do: node |> child_nodes() |> List.first()

  @doc "Returns the node's last child, or `nil` when it has none."
  def last_child(node), do: node |> child_nodes() |> List.last()

  @doc "Returns the node following this one under its parent, or `nil`."
  def next_sibling(node), do: sibling(node, 1)

  @doc "Returns the node preceding this one under its parent, or `nil`."
  def previous_sibling(node), do: sibling(node, -1)

  # first_child/last_child/next_sibling/previous_sibling are pure traversals
  # derivable from parent_node/1 and child_nodes/1, so they are defined once
  # here rather than per node type.
  defp sibling(node, offset) do
    if parent = parent_node(node) do
      siblings = child_nodes(parent)
      index = Enum.find_index(siblings, &(&1.id == node.id))
      target = index + offset
      if target >= 0, do: Enum.at(siblings, target)
    end
  end

  @doc """
  Returns the `DOM.Node.Document` that owns `node`, or `nil` when `node` is
  itself the document.
  """
  def owner_document(node), do: DOM._node_owner_document(node.server, node.id)
end
