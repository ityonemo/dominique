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
end
