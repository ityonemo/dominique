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
end
