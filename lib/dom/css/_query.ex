defmodule DOM.CSS.Query do
  @moduledoc false

  # ETS match-spec builders and the plumbing that runs them against the nodes
  # table for the DOM.CSS.* match/3 implementations. Selectors are matched by
  # running :ets.select with a defmatchspecp and intersecting the result with the
  # candidate id set; relational selectors chain multiple hits, pinning ids from
  # one hit into the next (see DOM.CSS.Complex / DOM.CSS.PseudoClass).

  use MatchSpec

  alias DOM.NodeData
  alias DOM.NodeData.Table

  @doc """
  Element ids in `candidates` whose local name is `name` — read from the tag
  index (a bounded prefix scan of the `:ordered_set`; namespace-agnostic, as CSS
  type selectors are), then intersected with the candidate scope.
  """
  @spec type(:ets.tid(), [reference()], String.t()) :: [reference()]
  def type(index, candidates, name) do
    index |> Table.index_lookup(:tag, name) |> intersect(candidates)
  end

  @doc "Element ids in `candidates` (the universal selector)."
  @spec elements(:ets.tid(), [reference()]) :: [reference()]
  def elements(nodes, candidates) do
    nodes |> select(element_spec()) |> intersect(candidates)
  end

  @doc """
  Element ids in `candidates` carrying `id` — read from the id index (a bounded
  prefix scan of the `:ordered_set`), then intersected with the candidate scope.
  """
  @spec id(:ets.tid(), [reference()], String.t()) :: [reference()]
  def id(index, candidates, id) do
    index |> Table.index_lookup(:id, id) |> intersect(candidates)
  end

  @doc """
  Element ids in `candidates` carrying class `token` — read from the class index
  (a bounded prefix scan of the `:ordered_set`), then intersected with the
  candidate scope.
  """
  @spec class(:ets.tid(), [reference()], String.t()) :: [reference()]
  def class(index, candidates, token) do
    index |> Table.index_lookup(:class, token) |> intersect(candidates)
  end

  @doc """
  Element ids in `candidates` matching an attribute selector, read from the attr
  index. With `op` nil this is a presence test; otherwise the value is matched
  per `op` (`:eq`, `:includes`, `:dash`, `:prefix`, `:suffix`, `:substring`),
  case-insensitively when `flag` is `:i`.

  Exact `[name=value]` (case-sensitive) is a point lookup on the
  `{:attr, name, value, _}` prefix; presence and every other operator (and any
  `i`-flagged compare) read all `{value, node_id}` under the name (a bounded
  by-name prefix scan) and filter the values here.
  """
  @spec attribute(
          :ets.tid(),
          [reference()],
          String.t(),
          DOM.CSS.attr_op() | nil,
          String.t() | nil,
          :i | :s | nil
        ) :: [reference()]
  def attribute(index, candidates, name, :eq, value, flag) when flag != :i do
    index |> Table.index_lookup(:attr, name, value) |> intersect(candidates)
  end

  def attribute(index, candidates, name, nil, _value, _flag) do
    matched = for {_value, node_id} <- Table.index_lookup_attr_name(index, name), do: node_id
    intersect(matched, candidates)
  end

  def attribute(index, candidates, name, op, value, flag) do
    matched =
      for {actual, node_id} <- Table.index_lookup_attr_name(index, name),
          value_match?(op, fold(actual, flag), fold(value, flag)),
          do: node_id

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

  @doc "All child ids of `node_id`, in document order (span-backed range scan)."
  @spec children_ids(DOM.CSS.context(), reference()) :: [reference()]
  def children_ids(%{nodes: nodes, index: index}, node_id) do
    Table.span_children_of(nodes, index, node_id)
  end

  @doc "Element children of `node_id`, in document order."
  @spec element_children(DOM.CSS.context(), reference()) :: [reference()]
  def element_children(%{nodes: nodes} = context, node_id) do
    context |> children_ids(node_id) |> Enum.filter(&element?(nodes, &1))
  end

  @doc "Preceding element siblings of `node_id`, nearest first."
  @spec prev_element_siblings(DOM.CSS.context(), reference()) :: [reference()]
  def prev_element_siblings(%{nodes: nodes} = context, node_id) do
    case parent(nodes, node_id) do
      nil ->
        []

      parent_id ->
        context
        |> element_children(parent_id)
        |> Enum.take_while(&(&1 != node_id))
        |> Enum.reverse()
    end
  end

  @doc "Element siblings of `node_id` (including itself), in document order."
  @spec element_siblings(DOM.CSS.context(), reference()) :: [reference()]
  def element_siblings(%{nodes: nodes} = context, node_id) do
    case parent(nodes, node_id) do
      nil -> [node_id]
      parent_id -> element_children(context, parent_id)
    end
  end

  @doc """
  Element siblings of `node_id` (including itself), in document order, that have
  the SAME element type — same `local_name` AND `namespace` (an SVG `<title>` and
  an HTML `<title>` are different types). Used by the `*-of-type` pseudo-classes.
  """
  @spec same_type_siblings(DOM.CSS.context(), reference()) :: [reference()]
  def same_type_siblings(%{nodes: nodes} = context, node_id) do
    {name, namespace} = element_type(nodes, node_id)

    context
    |> element_siblings(node_id)
    |> Enum.filter(&(element_type(nodes, &1) == {name, namespace}))
  end

  # The `{local_name, namespace}` of an element node.
  defp element_type(nodes, node_id) do
    [type] = select(nodes, element_type_spec(node_id))
    type
  end

  @doc """
  The value of attribute `name` on the nearest of `node_id`-or-ancestor that
  carries it, or `nil` if none does. Models the inheritance of `lang`/`dir`,
  which apply to a subtree from the element that declares them.
  """
  @spec inherited_attribute(:ets.tid(), reference(), String.t()) :: String.t() | nil
  def inherited_attribute(nodes, node_id, name) do
    [node_id | ancestors(nodes, node_id)]
    |> Enum.find_value(fn id -> own_attribute(nodes, id, name) end)
  end

  @doc "The value of attribute `name` set directly on `node_id`, or nil."
  @spec own_attribute(:ets.tid(), reference(), String.t()) :: String.t() | nil
  def own_attribute(nodes, node_id, name) do
    case select(nodes, attributes_of_spec(node_id)) do
      [attributes] ->
        case List.keyfind(attributes, name, 0) do
          {^name, value} -> value
          nil -> nil
        end

      [] ->
        nil
    end
  end

  @doc "Whether `node_id` has attribute `name` set directly (any value)."
  @spec has_own_attribute?(:ets.tid(), reference(), String.t()) :: boolean()
  def has_own_attribute?(nodes, node_id, name), do: own_attribute(nodes, node_id, name) != nil

  @doc "The HTML local name of `node_id` (nil if it is not an element)."
  @spec local_name(:ets.tid(), reference()) :: String.t() | nil
  def local_name(nodes, node_id) do
    case select(nodes, element_type_spec(node_id)) do
      [{name, _namespace}] -> name
      [] -> nil
    end
  end

  # Form-associated elements the disabled/enabled pseudo-classes apply to.
  @form_controls ~w(button input select textarea optgroup option fieldset)

  @doc """
  Whether `node_id` is a form control matched by `:disabled` (§ "actually
  disabled"): its own `disabled` attribute; or — for the control subset, not
  option/optgroup — a descendant of a `fieldset[disabled]`, EXCEPT when it is
  inside that fieldset's first `<legend>` child. `option` additionally inherits
  from an ancestor `optgroup[disabled]`.
  """
  @spec actually_disabled?(:ets.tid(), reference()) :: boolean()
  def actually_disabled?(nodes, node_id) do
    name = local_name(nodes, node_id)

    cond do
      name not in @form_controls -> false
      has_own_attribute?(nodes, node_id, "disabled") -> true
      name == "option" -> option_group_disabled?(nodes, node_id)
      name in ~w(optgroup) -> false
      :else -> disabled_by_fieldset?(nodes, node_id)
    end
  end

  # An option is disabled if an ancestor optgroup carries `disabled`.
  defp option_group_disabled?(nodes, node_id) do
    nodes
    |> ancestors(node_id)
    |> Enum.any?(
      &(local_name(nodes, &1) == "optgroup" and has_own_attribute?(nodes, &1, "disabled"))
    )
  end

  # A control is disabled by a fieldset[disabled] ancestor unless it sits inside
  # that fieldset's first <legend> child.
  defp disabled_by_fieldset?(nodes, node_id) do
    node_id
    |> ancestor_pairs(nodes)
    |> Enum.any?(fn {fieldset, child_toward_node} ->
      local_name(nodes, fieldset) == "fieldset" and
        has_own_attribute?(nodes, fieldset, "disabled") and
        child_toward_node != first_legend(nodes, fieldset)
    end)
  end

  # Each ancestor paired with the child of that ancestor that leads toward node_id
  # (so we can tell whether node_id descends through the fieldset's first legend).
  defp ancestor_pairs(node_id, nodes) do
    node_id
    |> ancestor_chain(nodes)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [child, ancestor] -> {ancestor, child} end)
  end

  # node_id, its parent, grandparent, … up to the root (inclusive of node_id).
  defp ancestor_chain(node_id, nodes), do: [node_id | ancestors(nodes, node_id)]

  # The first <legend> child of `fieldset`, or nil.
  defp first_legend(nodes, fieldset) do
    nodes
    |> Table.children(fieldset)
    |> Enum.find(&(local_name(nodes, &1) == "legend"))
  end

  @doc "Whether `node_id` is an element with no child element or text nodes."
  @spec empty?(DOM.CSS.context(), reference()) :: boolean()
  def empty?(%{nodes: nodes} = context, node_id) do
    context |> children_ids(node_id) |> Enum.all?(&(not content?(nodes, &1)))
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
  bounds where matching may start relative to `scope_id`. Takes the full match
  `context` because it recurses through `DOM.CSS.match/3`.
  """
  @spec has?([DOM.CSS.complex()], DOM.CSS.context(), reference()) :: boolean()
  def has?(list, context, scope_id) do
    Enum.any?(list, &relative_match?(&1, context, scope_id))
  end

  # Descendant ids of `node_id` in document order (all types; matching filters
  # to elements as needed).
  @spec descendants(DOM.CSS.context(), reference()) :: [reference()]
  def descendants(context, node_id) do
    context
    |> children_ids(node_id)
    |> Enum.flat_map(fn child -> [child | descendants(context, child)] end)
  end

  # A relative complex (from :has): split off the leading combinator, compute the
  # scope set relative to scope_id, then match the remaining complex over it.
  defp relative_match?(
         %DOM.CSS.Complex{parts: [combinator | rest]},
         context,
         scope_id
       )
       when is_atom(combinator) do
    scope = relative_scope(context, combinator, scope_id)
    remainder_matches?(rest, context, scope)
  end

  # No leading combinator: an implicit descendant relative selector.
  defp relative_match?(compound_or_complex, context, scope_id) do
    scope = relative_scope(context, :descendant, scope_id)
    remainder_matches?([compound_or_complex], context, scope)
  end

  defp relative_scope(context, :child, scope_id), do: element_children(context, scope_id)
  defp relative_scope(context, :descendant, scope_id), do: descendants(context, scope_id)

  defp relative_scope(context, :next_sibling, scope_id) do
    context |> next_element_siblings(scope_id) |> Enum.take(1)
  end

  defp relative_scope(context, :subsequent_sibling, scope_id) do
    next_element_siblings(context, scope_id)
  end

  defp next_element_siblings(%{nodes: nodes} = context, node_id) do
    case parent(nodes, node_id) do
      nil ->
        []

      parent_id ->
        context
        |> element_children(parent_id)
        |> Enum.drop_while(&(&1 != node_id))
        |> Enum.drop(1)
    end
  end

  # `rest` is [compound (comb compound)*] to match over `scope`.
  defp remainder_matches?([compound], context, scope) do
    DOM.CSS.match(compound, context, scope) != []
  end

  defp remainder_matches?(parts, context, scope) do
    DOM.CSS.match(%DOM.CSS.Complex{parts: parts}, context, scope) != []
  end

  # ==========================================================================
  # Match specs
  # ==========================================================================

  # Match specs use MAP patterns keyed on `__struct__`, which do subset matching:
  # only the mentioned keys are constrained, so per-type NodeData.* structs are
  # matched without pinning their other fields to defaults.
  defmatchspecp element_type_spec(node_id) do
    {^node_id, %{__struct__: NodeData.Element, local_name: name, namespace: namespace}} ->
      {name, namespace}
  end

  defmatchspecp element_spec() do
    {id, %{__struct__: NodeData.Element}} -> id
  end

  defmatchspecp attributes_of_spec(node_id) do
    {^node_id, %{__struct__: NodeData.Element, attributes: attributes}} -> attributes
  end

  defmatchspecp parent_spec(node_id) do
    {^node_id, %{parent: parent}} -> parent
  end

  defmatchspecp is_element_spec(node_id) do
    {^node_id, %{__struct__: NodeData.Element}} -> true
  end

  defmatchspecp content_spec(node_id) do
    {^node_id, %{__struct__: NodeData.Element}} -> true
    {^node_id, %{__struct__: NodeData.Text}} -> true
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
