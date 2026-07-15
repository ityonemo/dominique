defmodule DOM.CSS.Query do
  @moduledoc false

  # ETS match-spec builders and the plumbing that runs them against the nodes
  # table for the DOM.CSS.* match/3 implementations. Selectors are matched by
  # running :ets.select with a defmatchspecp and intersecting the result with the
  # candidate id set; relational selectors chain multiple hits, pinning ids from
  # one hit into the next (see DOM.CSS.Complex / DOM.CSS.PseudoClass).

  use MatchSpec

  alias DOM.NodeData
  alias DOM.NodeData.IndexTable
  alias DOM.NodeData.NodesTable

  # ==========================================================================
  # Protoset engine primitives (CSS combinator matching)
  # ==========================================================================
  #
  # A `protoset` is `%{ref => [leaf_ref]}`: key = the element currently being matched at this
  # stage of the right-to-left walk; value = the LEAF refs (the subject elements the query emits)
  # reachable through this current element. It is a LIST, not one ref, because a combinator is
  # one-to-many — one ancestor contains many subject leaves — so re-keying to the ancestor must
  # accumulate their leaves, not collapse them. Compounds are 1:1 (singleton lists). The fused ETS
  # specs guard/carry the value opaquely (never inspect it), so the list rides through untouched.

  @typedoc "A CSS-match protoset: current-element ref → the leaf refs reachable through it."
  @type protoset :: %{optional(reference()) => [reference()]}

  @doc "Seed a protoset from ids: `%{ref => [ref]}` (at the subject stage, current == its own leaf)."
  @spec seed([reference()]) :: protoset()
  def seed(ids), do: Map.new(ids, &{&1, [&1]})

  @doc "Keep the protoset entries whose KEY satisfies `fun` (value preserved)."
  @spec filter_protoset(protoset(), (reference() -> boolean())) :: protoset()
  def filter_protoset(protoset, fun), do: :maps.filter(fn id, _leaf -> fun.(id) end, protoset)

  @doc """
  Compound lookup fused with the protoset: the index scan's `is_map_key` guard IS the
  same-element intersection, and each surviving id keeps its leaf_ref. `kind` is
  `:id`/`:class`/`:tag`, or `:attr` with a `value2` for `[name=value]`.
  """
  @spec compound_lookup(:ets.tid(), protoset(), :id | :class | :tag, String.t()) :: protoset()
  def compound_lookup(index, protoset, kind, value) do
    index |> IndexTable.compound_lookup(protoset, kind, value) |> Map.new()
  end

  @spec compound_lookup(:ets.tid(), protoset(), :attr, String.t(), String.t()) :: protoset()
  def compound_lookup(index, protoset, :attr, name, value) do
    index |> IndexTable.compound_lookup(protoset, :attr, name, value) |> Map.new()
  end

  @doc "Universal (`*`) fused with the protoset: element rows whose id is in the protoset."
  @spec compound_element(:ets.tid(), protoset()) :: protoset()
  def compound_element(nodes, protoset) do
    nodes |> select(compound_element_spec(protoset)) |> Map.new()
  end

  defmatchspec compound_element_spec(protoset) do
    {id, %{__struct__: NodeData.Element}} when is_map_key(protoset, id) ->
      {id, :erlang.map_get(id, protoset)}
  end

  @typep ext ::
           {start :: binary(), id :: reference(), stop :: binary(), parent :: reference() | nil,
            root :: reference(), leaves :: [reference()]}

  @doc """
  Resolve a protoset to `{start, id, stop, parent, root, leaves}` tuples in **start-key
  (document) order**: one ordered `:start`-span scan (start/root/parent free from the row key,
  the leaf LIST from the protoset value), then `stop` joined from the records in one bulk select.
  `elements_only?` restricts to element rows (sibling combinators).
  """
  @spec resolve_extents(DOM.CSS.context(), protoset(), boolean()) :: [ext()]
  def resolve_extents(%{nodes: nodes, index: index}, protoset, elements_only? \\ false) do
    stops =
      nodes
      |> NodesTable.records_of(protoset)
      |> Map.new(fn {id, record} -> {id, record.stop} end)

    for {start, root, parent, id, leaves} <-
          IndexTable.span_starts(index, protoset, elements_only?) do
      {start, id, Map.fetch!(stops, id), parent, root, leaves}
    end
  end

  # Fold `{key, leaves}` pairs into `%{key => concatenated_leaves}` — the one-to-many merge
  # that makes a combinator join keep ALL leaves reaching a shared current element (`into: %{}`
  # would overwrite). Leaf-list dupes are harmless (the final result is order-filtered).
  defp merge_pairs(pairs) do
    Enum.reduce(pairs, %{}, fn {key, leaves}, acc ->
      Map.update(acc, key, leaves, &(leaves ++ &1))
    end)
  end

  @doc """
  Lift a protoset to its PARENTS: `%{parent_id => leaves}`, where each surviving subject's leaves
  are carried onto its parent (merge-appended for a shared parent). One span scan — the parent id
  is in the `:start` row. Backs the CSS `:child` combinator (then the left compound is an ordinary
  fused match over the parent-keyed protoset). Tree-root subjects (no parent) drop out.
  """
  @spec lift_to_parent(DOM.CSS.context(), protoset()) :: protoset()
  def lift_to_parent(%{index: index}, protoset) do
    index |> IndexTable.span_parents(protoset) |> merge_pairs()
  end

  @doc """
  Lift a protoset to each subject's IMMEDIATELY-preceding element sibling — `%{prev_sib_id =>
  leaves}` — backing the CSS `+` combinator. One element-span scan yields each subject's
  `{root, parent, start}`; per subject a single bounded (`limit 1`) reverse index probe finds its
  one preceding element sibling. Subjects with none drop out.
  """
  @spec lift_to_prev_sibling(DOM.CSS.context(), protoset()) :: protoset()
  def lift_to_prev_sibling(%{index: index}, protoset) do
    for {start, root, parent, _id, leaves} <- IndexTable.span_starts(index, protoset, true),
        sib = IndexTable.span_prev_element_sibling(index, root, parent, start),
        sib != nil do
      {sib, leaves}
    end
    |> merge_pairs()
  end

  @doc """
  Lift a protoset to ALL of each subject's preceding element siblings — `%{prev_sib_id => leaves}`
  — backing the CSS `~` combinator. One element-span scan for the subjects, then per subject a
  bounded reverse index range scan of its preceding element siblings.
  """
  @spec lift_to_prev_siblings(DOM.CSS.context(), protoset()) :: protoset()
  def lift_to_prev_siblings(%{index: index}, protoset) do
    for {start, root, parent, _id, leaves} <- IndexTable.span_starts(index, protoset, true),
        sib <- IndexTable.span_prev_element_siblings(index, root, parent, start) do
      {sib, leaves}
    end
    |> merge_pairs()
  end

  @doc """
  Containment join over start-sorted extents: a subject matches when some LEFT window (same
  `root`) strictly contains it (`left.start < subject.start and subject.stop < left.stop`).
  `projection` is `:subject` (key = subject id, the final step) or `:current` (key = the
  containing left id, feeding the next leftward step). The value is always the subject's leaves.
  """
  @spec resolve_descendants([ext()], [ext()], :subject | :current) :: protoset()
  def resolve_descendants(left_ext, subject_ext, projection) do
    # left windows grouped by root; sorted by start so the containment test is a scan.
    left_by_root = Enum.group_by(left_ext, fn {_s, _id, _stop, _p, root, _l} -> root end)

    for {s_start, s_id, s_stop, _s_parent, s_root, leaves} <- subject_ext,
        {l_start, l_id, l_stop, _l_parent, _l_root, _l_leaf} <-
          Map.get(left_by_root, s_root, []),
        l_start < s_start and s_stop < l_stop do
      case projection do
        :subject -> {s_id, leaves}
        :current -> {l_id, leaves}
      end
    end
    |> merge_pairs()
  end

  @doc """
  The protoset entries whose element has local name `name` — the tag index scan fused
  with the protoset (`compound_lookup`), leaf_refs preserved. (Namespace-agnostic, as CSS
  type selectors are.)
  """
  @spec type(:ets.tid(), protoset(), String.t()) :: protoset()
  def type(index, protoset, name), do: compound_lookup(index, protoset, :tag, name)

  @doc "The protoset entries that are elements (the universal selector `*`)."
  @spec elements(:ets.tid(), protoset()) :: protoset()
  def elements(nodes, protoset), do: compound_element(nodes, protoset)

  @doc "The protoset entries whose element carries `id` — id index fused with the protoset."
  @spec id(:ets.tid(), protoset(), String.t()) :: protoset()
  def id(index, protoset, id), do: compound_lookup(index, protoset, :id, id)

  @doc "The protoset entries whose element carries class `token` — class index fused with the protoset."
  @spec class(:ets.tid(), protoset(), String.t()) :: protoset()
  def class(index, protoset, token), do: compound_lookup(index, protoset, :class, token)

  @doc """
  The protoset entries whose element matches an attribute selector (leaf_refs preserved).
  `[name=value]` (case-sensitive) is a fused point lookup; presence and every other operator
  (and any `i`-flag) read `{value, id, leaf_ref}` under the name (fused by-name scan) and filter
  the values here.
  """
  @spec attribute(
          :ets.tid(),
          protoset(),
          String.t(),
          DOM.CSS.attr_op() | nil,
          String.t() | nil,
          :i | :s | nil
        ) :: protoset()
  def attribute(index, protoset, name, :eq, value, flag) when flag != :i do
    compound_lookup(index, protoset, :attr, name, value)
  end

  def attribute(index, protoset, name, nil, _value, _flag) do
    for {_value, id, leaf} <- IndexTable.compound_attr_name(index, protoset, name),
        into: %{},
        do: {id, leaf}
  end

  def attribute(index, protoset, name, op, value, flag) do
    for {actual, id, leaf} <- IndexTable.compound_attr_name(index, protoset, name),
        value_match?(op, fold(actual, flag), fold(value, flag)),
        into: %{},
        do: {id, leaf}
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

  @doc """
  Like `parent/2`, but crosses a shadow boundary: a node whose parent is a shadow
  root reports that shadow root's HOST as its parent, so `:host > x` matches. A
  bare shadow root reports its host too.
  """
  @spec shadow_parent(:ets.tid(), reference()) :: reference() | nil
  def shadow_parent(nodes, node_id) do
    case parent(nodes, node_id) do
      nil -> NodesTable.shadow_host(nodes, node_id)
      parent_id -> cross_shadow(nodes, parent_id)
    end
  end

  @doc "All shadow-crossing ancestor ids of `node_id`, nearest first (see `shadow_parent/2`)."
  @spec shadow_ancestors(:ets.tid(), reference()) :: [reference()]
  def shadow_ancestors(nodes, node_id) do
    case shadow_parent(nodes, node_id) do
      nil -> []
      parent_id -> [parent_id | shadow_ancestors(nodes, parent_id)]
    end
  end

  # If `id` is a shadow root, the boundary crosses to its host; else `id` itself.
  defp cross_shadow(nodes, id) do
    NodesTable.shadow_host(nodes, id) || id
  end

  @doc "All child ids of `node_id`, in document order (span-backed range scan)."
  @spec children_ids(DOM.CSS.context(), reference()) :: [reference()]
  def children_ids(%{nodes: nodes, index: index}, node_id) do
    DOM.NodeData.span_children_of(nodes, index, node_id)
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

  @doc "The value of attribute `name` (by qualified name) set directly on `node_id`, or nil."
  @spec own_attribute(:ets.tid(), reference(), String.t()) :: String.t() | nil
  def own_attribute(nodes, node_id, name) do
    case select(nodes, attributes_of_spec(node_id)) do
      [attributes] -> find_attribute_value(attributes, name)
      [] -> nil
    end
  end

  defp find_attribute_value(attributes, name) do
    case Enum.find(attributes, fn {key, _v} -> DOM.NodeData.Element.matches_key?(key, name) end) do
      {_key, value} -> value
      nil -> nil
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
    |> NodesTable.children(fieldset)
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

  # `rest` is [compound (comb compound)*] to match over `scope` (an id list; the leaf_ref
  # is irrelevant for :has, which only asks whether ANYTHING matches — so `seed/1` it and
  # test for a non-empty protoset).
  defp remainder_matches?([compound], context, scope) do
    DOM.CSS.match(compound, context, seed(scope)) != %{}
  end

  defp remainder_matches?(parts, context, scope) do
    DOM.CSS.match(%DOM.CSS.Complex{parts: parts}, context, seed(scope)) != %{}
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
