defmodule CSSTable do
  @moduledoc """
  Builds a raw `{node_id, %DOM.NodeData{}}` ETS table for unit-testing
  `DOM.CSS.match/3` directly, without a DOM GenServer.

  A tree is described with nested `element/3` calls:

      {table, ids} =
        CSSTable.build(
          element("root", [], [
            element("a", [{"class", "x"}], []),
            element("b", [{"id", "target"}], [])
          ])
        )

  `build/1` returns `{table, ids}` where `table` is the ETS tid and `ids` maps
  each element (by a caller-supplied `:as` label, else by document order index)
  to its node id. Use `ids` to assert which ids a selector matches.
  """

  alias DOM.NodeData
  alias DOM.NodeData.Table

  @doc """
  Describes an element node. `attributes` is a list of `{name, value}` tuples.
  Pass `as: label` in `attributes`? No — use `element/4` with opts for a label.
  """
  def element(local_name, attributes \\ [], children \\ [], opts \\ []) do
    %{
      kind: :element,
      local_name: local_name,
      attributes: attributes,
      children: children,
      label: opts[:as],
      namespace: opts[:namespace] || :html
    }
  end

  @doc "Describes a text node (childless leaf)."
  def text(value) do
    %{kind: :text, value: value}
  end

  @doc """
  Materializes a described tree into a fresh node table plus a populated id/class
  index, the shape `DOM.CSS.match/3` expects.

  Returns `{context, ids}` where `context` is `%{nodes: tid, index: tid}` and
  `ids` maps each labelled element's label (and every element's 0-based
  document-order index) to its node id.
  """
  def build(root) do
    table = :ets.new(:css_table, [:set, :public])
    index = :ets.new(:css_index, [:ordered_set, :public])
    {_next, ids} = insert(table, root, nil, 0, %{})
    Table.reindex(table, index)
    Table.span_build_all(table, index)
    {%{nodes: table, index: index}, ids}
  end

  # Inserts a node under `parent_id`; returns {next_index, ids}.
  defp insert(table, %{kind: :element} = node, parent_id, index, ids) do
    id = make_ref()
    {child_ids, next_index, ids} = insert_children(table, node.children, id, index + 1, ids)

    :ets.insert(
      table,
      {id,
       %NodeData.Element{
         local_name: node.local_name,
         namespace: node.namespace,
         attributes: node.attributes,
         parent: parent_id,
         children: child_ids
       }}
    )

    ids = Map.put(ids, index, id)
    ids = if node.label, do: Map.put(ids, node.label, id), else: ids
    {next_index, ids}
  end

  defp insert(table, %{kind: :text} = node, parent_id, index, ids) do
    id = make_ref()
    :ets.insert(table, {id, %NodeData.Text{value: node.value, parent: parent_id}})
    {index + 1, Map.put(ids, index, id)}
  end

  defp insert_children(table, children, parent_id, index, ids) do
    {child_ids, {next_index, ids}} =
      Enum.map_reduce(children, {index, ids}, fn child, {idx, acc} ->
        {new_idx, new_acc} = insert(table, child, parent_id, idx, acc)
        # the child's own id is the last one inserted at idx
        {Map.fetch!(new_acc, idx), {new_idx, new_acc}}
      end)

    {child_ids, next_index, ids}
  end
end
