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
end
