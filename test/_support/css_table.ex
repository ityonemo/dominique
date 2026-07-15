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
  alias DOM.NodeData.Extent
  alias DOM.NodeData.IndexTable

  require Extent
  @root_start Extent.root_start()
  @root_stop Extent.root_stop()

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
    {_next, ids, kids} = insert(table, root, nil, 0, %{}, %{})
    # Carve nested-set extents over the built tree (adjacency the matcher reads
    # comes from these + their span rows) — the shape DOM.CSS.match/3 expects.
    carve_extents(
      table,
      kids,
      Map.fetch!(ids, 0),
      Map.fetch!(ids, 0),
      nil,
      @root_start,
      @root_stop
    )

    # mirror span rows (from extents) and membership rows (tag/id/class) for every element.
    DOM.NodeData.span_index_all(table, index)

    for {id, %NodeData.Element{} = element} <- :ets.tab2list(table),
        do: IndexTable.index_put(index, id, element)

    {%{nodes: table, index: index}, ids}
  end

  # Inserts a node under `parent_id`; returns {next_index, ids, kids} where `kids`
  # maps each element id to its ordered child ids (the extent carve reads it, so no
  # NodeData `children` field is needed).
  defp insert(table, %{kind: :element} = node, parent_id, index, ids, kids) do
    id = make_ref()

    {child_ids, next_index, ids, kids} =
      insert_children(table, node.children, id, index + 1, ids, kids)

    :ets.insert(
      table,
      {
        id,
        # extent is placeholder (root: id, root window) — carve_extents overwrites it.
        %NodeData.Element{
          local_name: node.local_name,
          namespace: node.namespace,
          attributes: node.attributes,
          parent: parent_id,
          root: id,
          start: @root_start,
          stop: @root_stop
        }
      }
    )

    ids = Map.put(ids, index, id)
    ids = if node.label, do: Map.put(ids, node.label, id), else: ids
    {next_index, ids, Map.put(kids, id, child_ids)}
  end

  defp insert(table, %{kind: :text} = node, parent_id, index, ids, kids) do
    id = make_ref()
    # extent is placeholder (root: id, root window) — carve_extents overwrites it.
    :ets.insert(
      table,
      {id,
       %NodeData.Text{
         value: node.value,
         parent: parent_id,
         root: id,
         start: @root_start,
         stop: @root_stop
       }}
    )

    {index + 1, Map.put(ids, index, id), kids}
  end

  defp insert_children(table, children, parent_id, index, ids, kids) do
    {child_ids, {next_index, ids, kids}} =
      Enum.map_reduce(children, {index, ids, kids}, fn child, {idx, acc_ids, acc_kids} ->
        {new_idx, new_ids, new_kids} = insert(table, child, parent_id, idx, acc_ids, acc_kids)
        # the child's own id is the last one inserted at idx
        {Map.fetch!(new_ids, idx), {new_idx, new_ids, new_kids}}
      end)

    {child_ids, next_index, ids, kids}
  end

  # Carve nested-set extents over the tree from the `kids` map (id -> ordered child
  # ids), mirroring the tree builder's live extent assignment.
  defp carve_extents(table, kids, id, root, parent, start, stop) do
    [{^id, data}] = :ets.lookup(table, id)
    :ets.insert(table, {id, %{data | root: root, parent: parent, start: start, stop: stop}})

    kids
    |> Map.get(id, [])
    |> Enum.reduce(start, fn child, prev ->
      {cstart, cstop} = Extent.interval(prev, stop)
      carve_extents(table, kids, child, root, id, cstart, cstop)
      cstop
    end)
  end
end
