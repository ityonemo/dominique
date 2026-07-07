defmodule DOM.CSS.Query do
  @moduledoc false

  # ETS match-spec builders and the plumbing that runs them against the nodes
  # table for the DOM.CSS.* match/3 implementations. Selectors are matched by
  # running :ets.select with a defmatchspecp and intersecting the result with the
  # candidate id set; relational selectors chain multiple hits, pinning ids from
  # one hit into the next (see DOM.CSS.Complex / DOM.CSS.PseudoClass).

  use MatchSpec

  alias DOM.Node.Element
  alias DOM.NodeData

  @doc "Element ids in `candidates` whose local name is `name`."
  @spec type(:ets.tid(), [reference()], String.t()) :: [reference()]
  def type(nodes, candidates, name) do
    nodes |> select(type_spec(name)) |> intersect(candidates)
  end

  @doc "Element ids in `candidates` (the universal selector)."
  @spec elements(:ets.tid(), [reference()]) :: [reference()]
  def elements(nodes, candidates) do
    nodes |> select(element_spec()) |> intersect(candidates)
  end

  @doc "Element ids in `candidates` carrying an `id` attribute equal to `id`."
  @spec id(:ets.tid(), [reference()], String.t()) :: [reference()]
  def id(nodes, candidates, id) do
    attribute(nodes, candidates, "id", :eq, id, nil)
  end

  @doc "Element ids in `candidates` whose `class` attribute contains `token`."
  @spec class(:ets.tid(), [reference()], String.t()) :: [reference()]
  def class(nodes, candidates, token) do
    attribute(nodes, candidates, "class", :includes, token, nil)
  end

  @doc """
  Element ids in `candidates` matching an attribute selector. With `op` nil this
  is a presence test; otherwise the value is matched per `op` (`:eq`,
  `:includes`, `:dash`, `:prefix`, `:suffix`, `:substring`), case-insensitively
  when `flag` is `:i`.
  """
  @spec attribute(
          :ets.tid(),
          [reference()],
          String.t(),
          DOM.CSS.attr_op() | nil,
          String.t() | nil,
          :i | :s | nil
        ) :: [reference()]
  def attribute(nodes, candidates, name, op, value, flag) do
    matched =
      for {id, attributes} <- select(nodes, attributes_spec()),
          attribute_match?(attributes, name, op, value, flag),
          do: id

    intersect(matched, candidates)
  end

  @doc "The parent id of `node_id`, or `nil`."
  @spec parent(:ets.tid(), reference()) :: reference() | nil
  def parent(nodes, node_id) do
    case select(nodes, parent_spec(node_id)) do
      [parent_id] -> parent_id
      [] -> nil
    end
  end

  @doc "All ancestor ids of `node_id`, nearest first."
  @spec ancestors(:ets.tid(), reference()) :: [reference()]
  def ancestors(nodes, node_id) do
    case parent(nodes, node_id) do
      nil -> []
      parent_id -> [parent_id | ancestors(nodes, parent_id)]
    end
  end

  @doc "Element children of `node_id`, in document order."
  @spec element_children(:ets.tid(), reference()) :: [reference()]
  def element_children(nodes, node_id) do
    case select(nodes, children_spec(node_id)) do
      [children] -> Enum.filter(children, &element?(nodes, &1))
      [] -> []
    end
  end

  @doc "Preceding element siblings of `node_id`, nearest first."
  @spec prev_element_siblings(:ets.tid(), reference()) :: [reference()]
  def prev_element_siblings(nodes, node_id) do
    case parent(nodes, node_id) do
      nil ->
        []

      parent_id ->
        nodes
        |> element_children(parent_id)
        |> Enum.take_while(&(&1 != node_id))
        |> Enum.reverse()
    end
  end

  # ==========================================================================
  # Match specs
  # ==========================================================================

  # Unmentioned struct fields in a match spec are pinned to their defaults, so
  # every field we don't constrain must be an explicit wildcard variable.
  defmatchspecp type_spec(name) do
    {id,
     %NodeData{
       type: Element,
       local_name: ^name,
       name: _,
       public_id: _,
       system_id: _,
       value: _,
       parent: _,
       children: _,
       attributes: _
     }} ->
      id
  end

  defmatchspecp element_spec() do
    {id,
     %NodeData{
       type: Element,
       local_name: _,
       name: _,
       public_id: _,
       system_id: _,
       value: _,
       parent: _,
       children: _,
       attributes: _
     }} ->
      id
  end

  defmatchspecp attributes_spec() do
    {id,
     %NodeData{
       type: Element,
       local_name: _,
       name: _,
       public_id: _,
       system_id: _,
       value: _,
       parent: _,
       children: _,
       attributes: attributes
     }} ->
      {id, attributes}
  end

  defmatchspecp parent_spec(node_id) do
    {^node_id,
     %NodeData{
       type: _,
       local_name: _,
       name: _,
       public_id: _,
       system_id: _,
       value: _,
       parent: parent,
       children: _,
       attributes: _
     }} ->
      parent
  end

  defmatchspecp children_spec(node_id) do
    {^node_id,
     %NodeData{
       type: _,
       local_name: _,
       name: _,
       public_id: _,
       system_id: _,
       value: _,
       parent: _,
       children: children,
       attributes: _
     }} ->
      children
  end

  defmatchspecp is_element_spec(node_id) do
    {^node_id,
     %NodeData{
       type: Element,
       local_name: _,
       name: _,
       public_id: _,
       system_id: _,
       value: _,
       parent: _,
       children: _,
       attributes: _
     }} ->
      true
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp select(nodes, spec), do: :ets.select(nodes, spec)

  defp element?(nodes, node_id), do: select(nodes, is_element_spec(node_id)) == [true]

  # Keep only candidates that the spec matched, preserving candidate order.
  defp intersect(matched, candidates) do
    set = MapSet.new(matched)
    Enum.filter(candidates, &MapSet.member?(set, &1))
  end

  # Presence test when op is nil; otherwise compare the stored value per op.
  defp attribute_match?(attributes, name, nil, _value, _flag) do
    List.keymember?(attributes, name, 0)
  end

  defp attribute_match?(attributes, name, op, value, flag) do
    case List.keyfind(attributes, name, 0) do
      {^name, actual} -> value_match?(op, fold(actual, flag), fold(value, flag))
      nil -> false
    end
  end

  defp fold(string, :i), do: String.downcase(string)
  defp fold(string, _flag), do: string

  defp value_match?(_op, _actual, ""), do: false
  defp value_match?(:eq, actual, value), do: actual == value
  defp value_match?(:includes, actual, value), do: value in String.split(actual)

  defp value_match?(:dash, actual, value),
    do: actual == value or String.starts_with?(actual, value <> "-")

  defp value_match?(:prefix, actual, value), do: String.starts_with?(actual, value)
  defp value_match?(:suffix, actual, value), do: String.ends_with?(actual, value)
  defp value_match?(:substring, actual, value), do: String.contains?(actual, value)
end
