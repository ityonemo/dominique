defmodule DOM.CSS.Query do
  @moduledoc false

  # ETS match-spec builders and the plumbing that runs them against the nodes
  # table for the DOM.CSS.* match/3 implementations. Selectors are matched by
  # running :ets.select with a defmatchspecp and intersecting the result with the
  # candidate id set; relational selectors chain multiple hits, pinning ids from
  # one hit into the next (see DOM.CSS.Complex / DOM.CSS.PseudoClass).

  use MatchSpec

  alias DOM.Node.Element
  alias DOM.Node.Text
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

  @doc "Element siblings of `node_id` (including itself), in document order."
  @spec element_siblings(:ets.tid(), reference()) :: [reference()]
  def element_siblings(nodes, node_id) do
    case parent(nodes, node_id) do
      nil -> [node_id]
      parent_id -> element_children(nodes, parent_id)
    end
  end

  @doc "Whether `node_id` is an element with no child element or text nodes."
  @spec empty?(:ets.tid(), reference()) :: boolean()
  def empty?(nodes, node_id) do
    case select(nodes, children_spec(node_id)) do
      [children] -> not Enum.any?(children, &content?(nodes, &1))
      [] -> false
    end
  end

  @doc "Whether `node_id`'s parent is not an element (the document root element)."
  @spec root?(:ets.tid(), reference()) :: boolean()
  def root?(nodes, node_id) do
    case parent(nodes, node_id) do
      nil -> true
      parent_id -> not element?(nodes, parent_id)
    end
  end

  @doc """
  Whether any relative complex in `list` matches with `scope_id` as `:scope`.
  Each relative complex leads with a combinator (default `:descendant`) that
  bounds where matching may start relative to `scope_id`.
  """
  @spec has?([DOM.CSS.complex()], :ets.tid(), reference()) :: boolean()
  def has?(list, nodes, scope_id) do
    Enum.any?(list, &relative_match?(&1, nodes, scope_id))
  end

  # Descendant ids of `node_id` in document order (all types; matching filters
  # to elements as needed).
  @spec descendants(:ets.tid(), reference()) :: [reference()]
  def descendants(nodes, node_id) do
    nodes
    |> element_children_and_others(node_id)
    |> Enum.flat_map(fn child -> [child | descendants(nodes, child)] end)
  end

  defp element_children_and_others(nodes, node_id) do
    case select(nodes, children_spec(node_id)) do
      [children] -> children
      [] -> []
    end
  end

  # A relative complex (from :has): split off the leading combinator, compute the
  # scope set relative to scope_id, then match the remaining complex over it.
  defp relative_match?(%DOM.CSS.Complex{parts: [combinator | rest]}, nodes, scope_id)
       when is_atom(combinator) do
    scope = relative_scope(nodes, combinator, scope_id)
    remainder_matches?(rest, nodes, scope)
  end

  # No leading combinator: an implicit descendant relative selector.
  defp relative_match?(compound_or_complex, nodes, scope_id) do
    scope = relative_scope(nodes, :descendant, scope_id)
    remainder_matches?([compound_or_complex], nodes, scope)
  end

  defp relative_scope(nodes, :child, scope_id), do: element_children(nodes, scope_id)
  defp relative_scope(nodes, :descendant, scope_id), do: descendants(nodes, scope_id)

  defp relative_scope(nodes, :next_sibling, scope_id) do
    nodes |> next_element_siblings(scope_id) |> Enum.take(1)
  end

  defp relative_scope(nodes, :subsequent_sibling, scope_id) do
    next_element_siblings(nodes, scope_id)
  end

  defp next_element_siblings(nodes, node_id) do
    case parent(nodes, node_id) do
      nil ->
        []

      parent_id ->
        nodes
        |> element_children(parent_id)
        |> Enum.drop_while(&(&1 != node_id))
        |> Enum.drop(1)
    end
  end

  # `rest` is [compound (comb compound)*] to match over `scope`.
  defp remainder_matches?([compound], nodes, scope) do
    DOM.CSS.match(compound, nodes, scope) != []
  end

  defp remainder_matches?(parts, nodes, scope) do
    DOM.CSS.match(%DOM.CSS.Complex{parts: parts}, nodes, scope) != []
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

  defmatchspecp content_spec(node_id) do
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

    {^node_id,
     %NodeData{
       type: Text,
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

  # A node that counts as content for :empty — an element or a text node.
  defp content?(nodes, node_id), do: select(nodes, content_spec(node_id)) == [true]

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
