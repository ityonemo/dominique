defmodule DOM.CSS.PseudoClass do
  @moduledoc """
  A pseudo-class. The `arg` field carries the variant:

    * `nil` — a keyword pseudo-class, e.g. `:first-child`
    * `{a, b}` — an An+B `:nth-*` selector
    * `{a, b, selector_list}` — `:nth-*(An+B of S)`
    * `{:selector_list, list}` — `:not`/`:is`/`:where`/`:has(...)` (for `:has`,
      a relative complex in `list` may lead with a combinator)
    * `{:args, [ident]}` — `:lang`/`:dir(...)`
  """

  alias DOM.CSS.Query
  alias DOM.CSS.Serialize
  alias DOM.NodeData.IndexTable
  alias DOM.NodeData.NodesTable

  @enforce_keys [:name]
  defstruct [:name, arg: nil]

  use DOM.CSS

  @type arg ::
          nil
          | {integer(), integer()}
          | {integer(), integer(), [DOM.CSS.complex()]}
          | {:selector_list, [DOM.CSS.complex()]}
          | {:args, [String.t()]}

  @type t :: %__MODULE__{name: String.t(), arg: arg()}

  @impl DOM.CSS
  # Logical pseudo-classes (dispatch on arg). These recurse through DOM.CSS.match,
  # so they forward the whole `context`; the structural ones below only navigate
  # the tree and so destructure `%{nodes: nodes}`.
  def match(%{name: "not", arg: {:selector_list, list}}, context, protoset) do
    Map.drop(protoset, Map.keys(match_list(list, context, protoset)))
  end

  def match(%{name: name, arg: {:selector_list, list}}, context, protoset)
      when name in ["is", "where"] do
    match_list(list, context, protoset)
  end

  def match(%{name: "has", arg: {:selector_list, list}}, context, protoset) do
    Query.filter_protoset(protoset, &Query.has?(list, context, &1))
  end

  # Structural pseudo-classes (dispatch on name).
  def match(%{name: "root"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &Query.root?(nodes, &1))
  end

  def match(%{name: "empty"}, context, protoset) do
    Query.filter_protoset(protoset, &Query.empty?(context, &1))
  end

  def match(%{name: "first-child"}, context, protoset),
    do: nth(context, protoset, {0, 1}, :forward)

  def match(%{name: "last-child"}, context, protoset),
    do: nth(context, protoset, {0, 1}, :backward)

  def match(%{name: "only-child"}, context, protoset) do
    Query.filter_protoset(protoset, &(Query.element_siblings(context, &1) == [&1]))
  end

  def match(%{name: "nth-child", arg: {a, b}}, context, protoset)
      when is_integer(a) and is_integer(b) do
    nth(context, protoset, {a, b}, :forward)
  end

  def match(%{name: "nth-last-child", arg: {a, b}}, context, protoset)
      when is_integer(a) and is_integer(b) do
    nth(context, protoset, {a, b}, :backward)
  end

  def match(%{name: name, arg: {a, b, list}}, context, protoset)
      when name in ["nth-child", "nth-last-child"] and is_integer(a) and is_integer(b) do
    direction = if name == "nth-last-child", do: :backward, else: :forward
    nth_of(context, protoset, {a, b}, list, direction)
  end

  # of-type pseudo-classes: like the child variants but counting only siblings of
  # the SAME element type (same local_name + namespace).
  def match(%{name: "first-of-type"}, context, protoset),
    do: nth_type(context, protoset, {0, 1}, :forward)

  def match(%{name: "last-of-type"}, context, protoset),
    do: nth_type(context, protoset, {0, 1}, :backward)

  def match(%{name: "only-of-type"}, context, protoset) do
    Query.filter_protoset(protoset, &(Query.same_type_siblings(context, &1) == [&1]))
  end

  def match(%{name: "nth-of-type", arg: {a, b}}, context, protoset)
      when is_integer(a) and is_integer(b) do
    nth_type(context, protoset, {a, b}, :forward)
  end

  def match(%{name: "nth-last-of-type", arg: {a, b}}, context, protoset)
      when is_integer(a) and is_integer(b) do
    nth_type(context, protoset, {a, b}, :backward)
  end

  # Form-state pseudo-classes derivable from element name + attributes + ancestry
  # (no runtime interaction state). The interaction-state pseudos (:hover/:focus/
  # :active/:target and user-toggled :checked) remain match-nothing.
  @form_controls ~w(button input select textarea optgroup option fieldset)

  def match(%{name: "disabled"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &Query.actually_disabled?(nodes, &1))
  end

  def match(%{name: "enabled"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, fn id ->
      Query.local_name(nodes, id) in @form_controls and not Query.actually_disabled?(nodes, id)
    end)
  end

  def match(%{name: "required"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, fn id ->
      Query.local_name(nodes, id) in ~w(input select textarea) and
        Query.has_own_attribute?(nodes, id, "required")
    end)
  end

  def match(%{name: "optional"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, fn id ->
      Query.local_name(nodes, id) in ~w(input select textarea) and
        not Query.has_own_attribute?(nodes, id, "required")
    end)
  end

  # :checked — a checked checkbox/radio, or a selected option (attribute-derived;
  # user-toggled checkedness would be runtime state, deferred).
  def match(%{name: "checked"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &checked?(nodes, &1))
  end

  # :default — a checked input, a selected option, or the DEFAULT SUBMIT BUTTON of a
  # form (the first submit-capable control in the form's tree order).
  def match(%{name: "default"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, fn id ->
      (Query.local_name(nodes, id) == "input" and Query.has_own_attribute?(nodes, id, "checked")) or
        (Query.local_name(nodes, id) == "option" and
           Query.has_own_attribute?(nodes, id, "selected")) or
        default_submit_button?(nodes, id)
    end)
  end

  # :link — an unvisited hyperlink: an `a`/`area` with an `href` (visitedness is
  # navigation state, so :visited stays match-nothing and :link is all such links).
  # :any-link is identical here (it would be :link OR :visited, and :visited is empty).
  def match(%{name: name}, %{nodes: nodes}, protoset) when name in ["link", "any-link"] do
    Query.filter_protoset(protoset, fn id ->
      Query.local_name(nodes, id) in ~w(a area) and Query.has_own_attribute?(nodes, id, "href")
    end)
  end

  # :placeholder-shown — an input/textarea with a `placeholder` attribute and no value
  # (input: no `value` attribute; textarea: no text content).
  def match(%{name: "placeholder-shown"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &placeholder_shown?(nodes, &1))
  end

  # :defined — a built-in element (non-hyphenated name) or an UPGRADED custom element
  # (one carrying a definition on its record — set at create/define/adopt).
  def match(%{name: "defined"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, fn id ->
      not String.contains?(Query.local_name(nodes, id), "-") or upgraded?(nodes, id)
    end)
  end

  # :focus / :focus-visible — the document's active (focused) element. We do not model
  # a keyboard/mouse distinction, so :focus-visible aliases :focus for programmatic focus.
  def match(%{name: name}, %{index: index}, protoset)
      when name in ["focus", "focus-visible"] do
    case IndexTable.active_element_get(index) do
      nil -> %{}
      active -> Map.take(protoset, [active])
    end
  end

  # :focus-within — the active element or any of its ancestors.
  def match(%{name: "focus-within"}, %{nodes: nodes, index: index}, protoset) do
    ancestor_chain_match(protoset, nodes, IndexTable.active_element_get(index))
  end

  # :hover / :active — the hovered / pressed element or any of its ancestors (the
  # "hover chain"). Pointer state set by DOM.set_hover / set_active (no pointer input).
  def match(%{name: "hover"}, %{nodes: nodes, index: index}, protoset) do
    ancestor_chain_match(protoset, nodes, IndexTable.pointer_state_get(index, :hover))
  end

  def match(%{name: "active"}, %{nodes: nodes, index: index}, protoset) do
    ancestor_chain_match(protoset, nodes, IndexTable.pointer_state_get(index, :active))
  end

  # :target — the "indicated part of the document": the element whose id equals the
  # document fragment, or (when no id matches document-wide) an <a name=…> that equals
  # it. Case-sensitive; id takes precedence over name. We resolve the target across the
  # WHOLE document (not just `protoset`) so id-precedence holds even when the query
  # scope is a single name-anchor, then keep the protoset that are that target.
  def match(%{name: "target"}, %{nodes: nodes, index: index}, protoset) do
    case IndexTable.fragment_get(index) do
      nil -> %{}
      fragment -> Map.take(protoset, [target_id(nodes, index, fragment)])
    end
  end

  # :open — a <details> or <dialog> with the `open` attribute present.
  def match(%{name: "open"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, fn id ->
      Query.local_name(nodes, id) in ~w(details dialog) and
        Query.has_own_attribute?(nodes, id, "open")
    end)
  end

  # :indeterminate — a checkbox with its indeterminate property set; a radio whose whole
  # name group is unchecked; or a <progress> with no value attribute.
  def match(%{name: "indeterminate"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &indeterminate?(nodes, &1))
  end

  # :valid / :invalid — constraint validation. Only a "candidate" control participates
  # (form control, not barred/disabled); :invalid when any constraint fails, :valid otherwise.
  def match(%{name: "valid"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(
      protoset,
      &(validation_candidate?(nodes, &1) and not invalid?(nodes, &1))
    )
  end

  def match(%{name: "invalid"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &(validation_candidate?(nodes, &1) and invalid?(nodes, &1)))
  end

  # :in-range / :out-of-range — only range-limited inputs (with min and/or max). The
  # value is in range unless below min or above max.
  def match(%{name: "in-range"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &(range_limited?(nodes, &1) and not out_of_range?(nodes, &1)))
  end

  def match(%{name: "out-of-range"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &(range_limited?(nodes, &1) and out_of_range?(nodes, &1)))
  end

  def match(%{name: "read-write"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &read_write?(nodes, &1))
  end

  # :read-only — every element that is not :read-write.
  def match(%{name: "read-only"}, %{nodes: nodes}, protoset) do
    Query.filter_protoset(protoset, &(not read_write?(nodes, &1)))
  end

  # :scope — the scoping root of the query. `query_ids`/`matches` bind the
  # concrete root id into the arg before matching (DOM.CSS.bind_scope/2); an
  # unbound :scope (arg nil) has no root and matches nothing.
  def match(%{name: "scope", arg: {:scope, scope_id}}, _context, protoset) do
    Map.take(protoset, [scope_id])
  end

  # :host — the shadow host of the current shadow scope. Matches nothing outside a
  # shadow scope (scope_host nil), mirroring the browser.
  def match(%{name: "host", arg: nil}, %{scope_host: host}, protoset) do
    Map.take(protoset, [host])
  end

  # :host(sel) — the shadow host, if it matches `sel`.
  def match(%{name: "host", arg: {:selector_list, _}}, %{scope_host: nil}, _protoset), do: %{}

  def match(%{name: "host", arg: {:selector_list, list}}, context, protoset) do
    host = context.scope_host

    if match_list(list, context, Query.seed([host])) != %{},
      do: Map.take(protoset, [host]),
      else: %{}
  end

  # :host-context(sel) — the host, when the host or one of its (light-tree)
  # ancestors matches `sel`.
  def match(%{name: "host-context", arg: {:selector_list, _}}, %{scope_host: nil}, _proto),
    do: %{}

  def match(%{name: "host-context", arg: {:selector_list, list}}, context, protoset) do
    host = context.scope_host
    chain = [host | Query.ancestors(context.nodes, host)]

    if Enum.any?(chain, &(match_list(list, context, Query.seed([&1])) != %{})) do
      Map.take(protoset, [host])
    else
      %{}
    end
  end

  # :lang(A, B, …) — the element's inherited `lang` (nearest ancestor-or-self
  # bearing one) matches one of the args by the `|=` rule: equal, or a prefix
  # followed by "-", case-insensitively (BCP-47 subtags).
  def match(%{name: "lang", arg: {:args, langs}}, %{nodes: nodes}, protoset) do
    wanted = Enum.map(langs, &String.downcase/1)

    nodes
    |> Query.elements(protoset)
    |> Query.filter_protoset(fn id ->
      case Query.inherited_attribute(nodes, id, "lang") do
        nil -> false
        value -> Enum.any?(wanted, &lang_matches?(String.downcase(value), &1))
      end
    end)
  end

  # :dir(ltr|rtl) — the element's inherited `dir` attribute equals the keyword.
  # :dir(auto) needs bidi resolution of the element's text, which NodeData does
  # not model, so it matches nothing (falls through to the catch-all).
  def match(%{name: "dir", arg: {:args, [dir]}}, %{nodes: nodes}, protoset)
      when dir in ["ltr", "rtl"] do
    nodes
    |> Query.elements(protoset)
    |> Query.filter_protoset(fn id ->
      value = Query.inherited_attribute(nodes, id, "dir")
      value != nil and String.downcase(value) == dir
    end)
  end

  # Anything else (UI/state pseudo-classes, :dir(auto), unknowns) matches
  # nothing — mirrors the browser, where e.g. :hover yields no elements in a
  # static querySelector rather than erroring.
  def match(_selector, _context, _protoset), do: %{}

  # Input types the `readonly` attribute applies to (so :read-write can match them).
  @readonly_input_types ~w(text search url tel email password date month week time
                           datetime-local number)

  # A checked checkbox/radio (by the `checked` attribute) or a selected option.
  defp checked?(nodes, id) do
    case Query.local_name(nodes, id) do
      "input" ->
        input_type(nodes, id) in ~w(checkbox radio) and input_checkedness(nodes, id)

      "option" ->
        Query.has_own_attribute?(nodes, id, "selected")

      _ ->
        false
    end
  end

  # An input's checkedness: the `checked` OVERRIDE field if set (dirty / user-toggled),
  # else the `checked` attribute (clean default). See NodeData.Element.
  defp input_checkedness(nodes, id) do
    case NodesTable.fetch!(nodes, id).checked do
      nil -> Query.has_own_attribute?(nodes, id, "checked")
      value -> value
    end
  end

  # :placeholder-shown — has a `placeholder` and is empty. input: no `value` attribute;
  # textarea: no text content.
  defp placeholder_shown?(nodes, id) do
    Query.has_own_attribute?(nodes, id, "placeholder") and
      case Query.local_name(nodes, id) do
        "input" -> Query.own_attribute(nodes, id, "value") in [nil, ""]
        "textarea" -> textarea_text(nodes, id) == ""
        _ -> false
      end
  end

  # The concatenated text of a textarea's direct text-node children.
  defp textarea_text(nodes, id) do
    for child <- NodesTable.children(nodes, id),
        %DOM.NodeData.Text{value: value} <- [NodesTable.fetch!(nodes, child)],
        into: "",
        do: value
  end

  # A candidate for constraint validation: a form control (input/select/textarea) that
  # is not barred (not disabled, and — for input — not a barred type).
  @barred_input_types ~w(hidden button reset submit image)
  defp validation_candidate?(nodes, id) do
    case Query.local_name(nodes, id) do
      "input" ->
        not Query.actually_disabled?(nodes, id) and
          input_type(nodes, id) not in @barred_input_types

      name when name in ~w(select textarea) ->
        not Query.actually_disabled?(nodes, id)

      _ ->
        false
    end
  end

  # Any failing constraint makes a candidate :invalid.
  defp invalid?(nodes, id) do
    required_empty?(nodes, id) or type_mismatch?(nodes, id) or
      pattern_mismatch?(nodes, id) or (range_limited?(nodes, id) and out_of_range?(nodes, id))
  end

  defp required_empty?(nodes, id) do
    Query.has_own_attribute?(nodes, id, "required") and control_value(nodes, id) in [nil, ""]
  end

  # type=email / type=url with a non-empty value that doesn't match a pragmatic format.
  defp type_mismatch?(nodes, id) do
    value = control_value(nodes, id)

    cond do
      value in [nil, ""] -> false
      input_type(nodes, id) == "email" -> not Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, value)
      input_type(nodes, id) == "url" -> not Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/, value)
      :else -> false
    end
  end

  # A `pattern` that the (non-empty) value does not FULLY match.
  defp pattern_mismatch?(nodes, id) do
    value = control_value(nodes, id)
    pattern = Query.own_attribute(nodes, id, "pattern")

    if pattern == nil or value in [nil, ""] do
      false
    else
      case compile_anchored(pattern) do
        :error -> false
        regex -> not Regex.match?(regex, value)
      end
    end
  end

  defp compile_anchored(pattern) do
    case Regex.compile("\\A(?:" <> pattern <> ")\\z", "u") do
      {:ok, regex} -> regex
      {:error, _} -> :error
    end
  end

  # An input is range-limited if it carries min and/or max (a range-supporting type).
  defp range_limited?(nodes, id) do
    Query.local_name(nodes, id) == "input" and
      input_type(nodes, id) in ~w(number range date month week time datetime-local) and
      (Query.has_own_attribute?(nodes, id, "min") or Query.has_own_attribute?(nodes, id, "max"))
  end

  # The value is out of range: below min or above max (numeric compare).
  defp out_of_range?(nodes, id) do
    case parse_number(control_value(nodes, id)) do
      value when is_float(value) -> below_min?(nodes, id, value) or above_max?(nodes, id, value)
      nil -> false
    end
  end

  defp below_min?(nodes, id, value) do
    case parse_number(Query.own_attribute(nodes, id, "min")) do
      min when is_float(min) -> value < min
      _ -> false
    end
  end

  defp above_max?(nodes, id, value) do
    case parse_number(Query.own_attribute(nodes, id, "max")) do
      max when is_float(max) -> value > max
      _ -> false
    end
  end

  defp parse_number(nil), do: nil

  defp parse_number(string) do
    case Float.parse(string) do
      {number, ""} -> number
      _ -> nil
    end
  end

  # A control's value for validation: the `value` attribute for input; text for textarea.
  defp control_value(nodes, id) do
    case Query.local_name(nodes, id) do
      "textarea" -> textarea_text(nodes, id)
      _ -> Query.own_attribute(nodes, id, "value")
    end
  end

  # :indeterminate sources: a checkbox with the indeterminate property; a radio whose
  # whole name group is unchecked; a <progress> with no value.
  defp indeterminate?(nodes, id) do
    case NodesTable.fetch!(nodes, id) do
      %DOM.NodeData.Element{local_name: "input"} = el ->
        indeterminate_input?(nodes, id, el)

      %DOM.NodeData.Element{local_name: "progress"} ->
        not Query.has_own_attribute?(nodes, id, "value")

      _ ->
        false
    end
  end

  defp indeterminate_input?(nodes, id, el) do
    case input_type(nodes, id) do
      "checkbox" -> el.indeterminate
      "radio" -> radio_group_unchecked?(nodes, id)
      _ -> false
    end
  end

  # True when no radio in `id`'s name group (document scope) is checked.
  defp radio_group_unchecked?(nodes, id) do
    name = Query.own_attribute(nodes, id, "name")

    nodes
    |> NodesTable.elements_by_tag_name(Process.get(:document_id), "input")
    |> Enum.filter(
      &(input_type(nodes, &1) == "radio" and Query.own_attribute(nodes, &1, "name") == name)
    )
    |> Enum.all?(&(not input_checkedness(nodes, &1)))
  end

  # :read-write — a mutable input (a type the `readonly` attribute applies to,
  # without `readonly`/`disabled`), a mutable textarea, or a contenteditable host.
  # Filter `protoset` to keys on the `target`-inclusive ancestor chain (target or an
  # ancestor of it) — shared by :focus-within / :hover / :active. Empty when target nil.
  defp ancestor_chain_match(_protoset, _nodes, nil), do: %{}

  defp ancestor_chain_match(protoset, nodes, target) do
    chain = MapSet.new([target | Query.ancestors(nodes, target)])
    Query.filter_protoset(protoset, &MapSet.member?(chain, &1))
  end

  # An upgraded custom element carries a definition on its record.
  defp upgraded?(nodes, id) do
    match?(%DOM.NodeData.Element{definition: def} when def != nil, NodesTable.fetch!(nodes, id))
  end

  # The document's :target element for `fragment`: the first element with id==fragment
  # (via the id index), else the first <a name==fragment> in document order, else nil.
  defp target_id(nodes, index, fragment) do
    case IndexTable.index_lookup(index, :id, fragment) do
      [id | _] -> id
      [] -> named_anchor(nodes, fragment)
    end
  end

  defp named_anchor(nodes, fragment) do
    nodes
    |> NodesTable.elements_by_tag_name(Process.get(:document_id), "a")
    |> Enum.find(&(Query.own_attribute(nodes, &1, "name") == fragment))
  end

  defp read_write?(nodes, id) do
    case Query.local_name(nodes, id) do
      "input" ->
        input_type(nodes, id) in @readonly_input_types and mutable?(nodes, id)

      "textarea" ->
        mutable?(nodes, id)

      nil ->
        false

      _ ->
        editable?(nodes, id)
    end
  end

  # Whether `id` is the default submit button of its form: a submit-capable control
  # that is the FIRST such control in its owning <form>'s tree order.
  defp default_submit_button?(nodes, id) do
    submit_control?(nodes, id) and
      case form_of(nodes, id) do
        nil -> false
        form -> first_submit_control(nodes, form) == id
      end
  end

  # A submit-capable control: a <button> (submit is its default type unless type is
  # given as reset/button) or an <input type=submit|image>.
  defp submit_control?(nodes, id) do
    case Query.local_name(nodes, id) do
      "button" -> Query.own_attribute(nodes, id, "type") in [nil, "submit"]
      "input" -> input_type(nodes, id) in ~w(submit image)
      _ -> false
    end
  end

  defp form_of(nodes, id) do
    Enum.find(Query.ancestors(nodes, id), &(Query.local_name(nodes, &1) == "form"))
  end

  defp first_submit_control(nodes, form) do
    nodes
    |> NodesTable.descendant_ids(form)
    |> Enum.find(&submit_control?(nodes, &1))
  end

  # A control is mutable when it has neither `readonly` nor `disabled`.
  defp mutable?(nodes, id) do
    not Query.has_own_attribute?(nodes, id, "readonly") and
      not Query.actually_disabled?(nodes, id)
  end

  # An editing host: the nearest inclusive ancestor with a `contenteditable` value
  # decides — a value other than "false" makes the element editable, "false" (or no
  # such ancestor) makes it not. This models contenteditable INHERITANCE.
  defp editable?(nodes, id) do
    [id | Query.ancestors(nodes, id)]
    |> Enum.find_value(fn ancestor ->
      case Query.own_attribute(nodes, ancestor, "contenteditable") do
        nil -> nil
        value -> {String.downcase(value) != "false"}
      end
    end)
    |> case do
      {editable?} -> editable?
      nil -> false
    end
  end

  # An input's `type` (defaulting to "text" when absent), lower-cased.
  defp input_type(nodes, id) do
    case Query.own_attribute(nodes, id, "type") do
      nil -> "text"
      value -> String.downcase(value)
    end
  end

  # An+B position test among element siblings, counting from the start
  # (:forward) or end (:backward). Filters the protoset (leaf_refs preserved).
  defp nth(context, protoset, {a, b}, direction) do
    nth_among(protoset, direction, {a, b}, &Query.element_siblings(context, &1))
  end

  # An+B among same-type element siblings (the *-of-type variants).
  defp nth_type(context, protoset, {a, b}, direction) do
    nth_among(protoset, direction, {a, b}, &Query.same_type_siblings(context, &1))
  end

  # Keep each protoset key whose 1-based position, within the sibling set produced by
  # `siblings_fun` (reversed for :backward), satisfies An+B.
  defp nth_among(protoset, direction, {a, b}, siblings_fun) do
    Query.filter_protoset(protoset, fn id ->
      siblings = siblings_fun.(id)
      siblings = if direction == :backward, do: Enum.reverse(siblings), else: siblings
      index = Enum.find_index(siblings, &(&1 == id))
      index != nil and anb?(index + 1, a, b)
    end)
  end

  # :nth-*(An+B of S) — index among siblings that also match the selector list S.
  defp nth_of(context, protoset, {a, b}, list, direction) do
    Query.filter_protoset(protoset, fn id ->
      siblings = Query.element_siblings(context, id)
      matching_set = match_list(list, context, Query.seed(siblings))
      matching = Enum.filter(siblings, &is_map_key(matching_set, &1))
      matching = if direction == :backward, do: Enum.reverse(matching), else: matching
      index = Enum.find_index(matching, &(&1 == id))
      index != nil and anb?(index + 1, a, b)
    end)
  end

  # The `|=` match used by :lang — value equals wanted, or begins with it plus a
  # "-" boundary (so `en` matches `en-US` but not `english`). Both downcased.
  defp lang_matches?(value, wanted) do
    value == wanted or String.starts_with?(value, wanted <> "-")
  end

  # Does `position` satisfy An+B, i.e. exists k >= 0 with position == a*k + b?
  defp anb?(position, 0, b), do: position == b
  defp anb?(position, a, b), do: rem(position - b, a) == 0 and div(position - b, a) >= 0

  # Match each complex in `list` over the SAME protoset and union the results (map merge,
  # leaf_refs preserved). Backs :is/:where/:not/:has/:host()/:nth-of.
  defp match_list(list, context, protoset) do
    Enum.reduce(list, %{}, fn complex, acc ->
      Map.merge(acc, DOM.CSS.match(complex, context, protoset))
    end)
  end

  defimpl String.Chars do
    def to_string(%{name: name, arg: nil}), do: ":" <> Serialize.escape_ident(name)

    def to_string(%{name: name, arg: {a, b}}) when is_integer(a) and is_integer(b) do
      ":" <> Serialize.escape_ident(name) <> "(" <> Serialize.anb(a, b) <> ")"
    end

    def to_string(%{name: name, arg: {a, b, list}}) when is_integer(a) and is_integer(b) do
      ":" <>
        Serialize.escape_ident(name) <>
        "(" <> Serialize.anb(a, b) <> " of " <> Serialize.selector_list(list) <> ")"
    end

    def to_string(%{name: name, arg: {:selector_list, list}}) do
      ":" <> Serialize.escape_ident(name) <> "(" <> Serialize.selector_list(list) <> ")"
    end

    def to_string(%{name: name, arg: {:args, args}}) do
      rendered = Enum.map_join(args, ", ", &Serialize.escape_ident/1)
      ":" <> Serialize.escape_ident(name) <> "(" <> rendered <> ")"
    end
  end
end
