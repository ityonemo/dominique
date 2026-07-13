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
  alias DOM.NodeData.Table

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
  def match(%{name: "not", arg: {:selector_list, list}}, context, candidates) do
    matched = match_list(list, context, candidates)
    candidates -- matched
  end

  def match(%{name: name, arg: {:selector_list, list}}, context, candidates)
      when name in ["is", "where"] do
    match_list(list, context, candidates)
  end

  def match(%{name: "has", arg: {:selector_list, list}}, context, candidates) do
    Enum.filter(candidates, &Query.has?(list, context, &1))
  end

  # Structural pseudo-classes (dispatch on name).
  def match(%{name: "root"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, &Query.root?(nodes, &1))
  end

  def match(%{name: "empty"}, context, candidates) do
    Enum.filter(candidates, &Query.empty?(context, &1))
  end

  def match(%{name: "first-child"}, context, candidates),
    do: nth(context, candidates, {0, 1}, :forward)

  def match(%{name: "last-child"}, context, candidates),
    do: nth(context, candidates, {0, 1}, :backward)

  def match(%{name: "only-child"}, context, candidates) do
    Enum.filter(candidates, &(Query.element_siblings(context, &1) == [&1]))
  end

  def match(%{name: "nth-child", arg: {a, b}}, context, candidates)
      when is_integer(a) and is_integer(b) do
    nth(context, candidates, {a, b}, :forward)
  end

  def match(%{name: "nth-last-child", arg: {a, b}}, context, candidates)
      when is_integer(a) and is_integer(b) do
    nth(context, candidates, {a, b}, :backward)
  end

  def match(%{name: name, arg: {a, b, list}}, context, candidates)
      when name in ["nth-child", "nth-last-child"] and is_integer(a) and is_integer(b) do
    direction = if name == "nth-last-child", do: :backward, else: :forward
    nth_of(context, candidates, {a, b}, list, direction)
  end

  # of-type pseudo-classes: like the child variants but counting only siblings of
  # the SAME element type (same local_name + namespace).
  def match(%{name: "first-of-type"}, context, candidates),
    do: nth_type(context, candidates, {0, 1}, :forward)

  def match(%{name: "last-of-type"}, context, candidates),
    do: nth_type(context, candidates, {0, 1}, :backward)

  def match(%{name: "only-of-type"}, context, candidates) do
    Enum.filter(candidates, &(Query.same_type_siblings(context, &1) == [&1]))
  end

  def match(%{name: "nth-of-type", arg: {a, b}}, context, candidates)
      when is_integer(a) and is_integer(b) do
    nth_type(context, candidates, {a, b}, :forward)
  end

  def match(%{name: "nth-last-of-type", arg: {a, b}}, context, candidates)
      when is_integer(a) and is_integer(b) do
    nth_type(context, candidates, {a, b}, :backward)
  end

  # Form-state pseudo-classes derivable from element name + attributes + ancestry
  # (no runtime interaction state). The interaction-state pseudos (:hover/:focus/
  # :active/:target and user-toggled :checked) remain match-nothing.
  @form_controls ~w(button input select textarea optgroup option fieldset)

  def match(%{name: "disabled"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, &Query.actually_disabled?(nodes, &1))
  end

  def match(%{name: "enabled"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, fn id ->
      Query.local_name(nodes, id) in @form_controls and not Query.actually_disabled?(nodes, id)
    end)
  end

  def match(%{name: "required"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, fn id ->
      Query.local_name(nodes, id) in ~w(input select textarea) and
        Query.has_own_attribute?(nodes, id, "required")
    end)
  end

  def match(%{name: "optional"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, fn id ->
      Query.local_name(nodes, id) in ~w(input select textarea) and
        not Query.has_own_attribute?(nodes, id, "required")
    end)
  end

  # :checked — a checked checkbox/radio, or a selected option (attribute-derived;
  # user-toggled checkedness would be runtime state, deferred).
  def match(%{name: "checked"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, &checked?(nodes, &1))
  end

  # :default — a checked input, a selected option, or the DEFAULT SUBMIT BUTTON of a
  # form (the first submit-capable control in the form's tree order).
  def match(%{name: "default"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, fn id ->
      (Query.local_name(nodes, id) == "input" and Query.has_own_attribute?(nodes, id, "checked")) or
        (Query.local_name(nodes, id) == "option" and
           Query.has_own_attribute?(nodes, id, "selected")) or
        default_submit_button?(nodes, id)
    end)
  end

  # :link — an unvisited hyperlink: an `a`/`area` with an `href` (visitedness is
  # navigation state, so :visited stays match-nothing and :link is all such links).
  def match(%{name: "link"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, fn id ->
      Query.local_name(nodes, id) in ~w(a area) and Query.has_own_attribute?(nodes, id, "href")
    end)
  end

  # :defined — a built-in element (non-hyphenated name) or an UPGRADED custom element
  # (one carrying a definition on its record — set at create/define/adopt).
  def match(%{name: "defined"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, fn id ->
      not String.contains?(Query.local_name(nodes, id), "-") or upgraded?(nodes, id)
    end)
  end

  # :focus / :focus-visible — the document's active (focused) element. We do not model
  # a keyboard/mouse distinction, so :focus-visible aliases :focus for programmatic focus.
  def match(%{name: name}, %{index: index}, candidates)
      when name in ["focus", "focus-visible"] do
    case Table.active_element_get(index) do
      nil -> []
      active -> Enum.filter(candidates, &(&1 == active))
    end
  end

  # :focus-within — the active element or any of its ancestors.
  def match(%{name: "focus-within"}, %{nodes: nodes, index: index}, candidates) do
    ancestor_chain_match(candidates, nodes, Table.active_element_get(index))
  end

  # :hover / :active — the hovered / pressed element or any of its ancestors (the
  # "hover chain"). Pointer state set by DOM.set_hover / set_active (no pointer input).
  def match(%{name: "hover"}, %{nodes: nodes, index: index}, candidates) do
    ancestor_chain_match(candidates, nodes, Table.pointer_state_get(index, :hover))
  end

  def match(%{name: "active"}, %{nodes: nodes, index: index}, candidates) do
    ancestor_chain_match(candidates, nodes, Table.pointer_state_get(index, :active))
  end

  # :target — the "indicated part of the document": the element whose id equals the
  # document fragment, or (when no id matches document-wide) an <a name=…> that equals
  # it. Case-sensitive; id takes precedence over name. We resolve the target across the
  # WHOLE document (not just `candidates`) so id-precedence holds even when the query
  # scope is a single name-anchor, then keep the candidates that are that target.
  def match(%{name: "target"}, %{nodes: nodes, index: index}, candidates) do
    case Table.fragment_get(index) do
      nil -> []
      fragment -> Enum.filter(candidates, &(&1 == target_id(nodes, index, fragment)))
    end
  end

  # :open — a <details> or <dialog> with the `open` attribute present.
  def match(%{name: "open"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, fn id ->
      Query.local_name(nodes, id) in ~w(details dialog) and
        Query.has_own_attribute?(nodes, id, "open")
    end)
  end

  def match(%{name: "read-write"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, &read_write?(nodes, &1))
  end

  # :read-only — every element that is not :read-write.
  def match(%{name: "read-only"}, %{nodes: nodes}, candidates) do
    Enum.filter(candidates, &(not read_write?(nodes, &1)))
  end

  # :scope — the scoping root of the query. `query_ids`/`matches` bind the
  # concrete root id into the arg before matching (DOM.CSS.bind_scope/2); an
  # unbound :scope (arg nil) has no root and matches nothing.
  def match(%{name: "scope", arg: {:scope, scope_id}}, _context, candidates) do
    Enum.filter(candidates, &(&1 == scope_id))
  end

  # :host — the shadow host of the current shadow scope. Matches nothing outside a
  # shadow scope (scope_host nil), mirroring the browser.
  def match(%{name: "host", arg: nil}, %{scope_host: host}, candidates) do
    Enum.filter(candidates, &(&1 == host))
  end

  # :host(sel) — the shadow host, if it matches `sel`.
  def match(%{name: "host", arg: {:selector_list, _}}, %{scope_host: nil}, _candidates), do: []

  def match(%{name: "host", arg: {:selector_list, list}}, context, candidates) do
    host = context.scope_host

    if match_list(list, context, [host]) != [],
      do: Enum.filter(candidates, &(&1 == host)),
      else: []
  end

  # :host-context(sel) — the host, when the host or one of its (light-tree)
  # ancestors matches `sel`.
  def match(%{name: "host-context", arg: {:selector_list, _}}, %{scope_host: nil}, _cands), do: []

  def match(%{name: "host-context", arg: {:selector_list, list}}, context, candidates) do
    host = context.scope_host
    chain = [host | Query.ancestors(context.nodes, host)]

    if Enum.any?(chain, &(match_list(list, context, [&1]) != [])) do
      Enum.filter(candidates, &(&1 == host))
    else
      []
    end
  end

  # :lang(A, B, …) — the element's inherited `lang` (nearest ancestor-or-self
  # bearing one) matches one of the args by the `|=` rule: equal, or a prefix
  # followed by "-", case-insensitively (BCP-47 subtags).
  def match(%{name: "lang", arg: {:args, langs}}, %{nodes: nodes}, candidates) do
    wanted = Enum.map(langs, &String.downcase/1)

    nodes
    |> Query.elements(candidates)
    |> Enum.filter(fn id ->
      case Query.inherited_attribute(nodes, id, "lang") do
        nil -> false
        value -> Enum.any?(wanted, &lang_matches?(String.downcase(value), &1))
      end
    end)
  end

  # :dir(ltr|rtl) — the element's inherited `dir` attribute equals the keyword.
  # :dir(auto) needs bidi resolution of the element's text, which NodeData does
  # not model, so it matches nothing (falls through to the catch-all).
  def match(%{name: "dir", arg: {:args, [dir]}}, %{nodes: nodes}, candidates)
      when dir in ["ltr", "rtl"] do
    nodes
    |> Query.elements(candidates)
    |> Enum.filter(fn id ->
      value = Query.inherited_attribute(nodes, id, "dir")
      value != nil and String.downcase(value) == dir
    end)
  end

  # Anything else (UI/state pseudo-classes, :dir(auto), unknowns) matches
  # nothing — mirrors the browser, where e.g. :hover yields no elements in a
  # static querySelector rather than erroring.
  def match(_selector, _context, _candidates), do: []

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
    case Table.fetch!(nodes, id).checked do
      nil -> Query.has_own_attribute?(nodes, id, "checked")
      value -> value
    end
  end

  # :read-write — a mutable input (a type the `readonly` attribute applies to,
  # without `readonly`/`disabled`), a mutable textarea, or a contenteditable host.
  # Filter `candidates` to those on the `target`-inclusive ancestor chain (target or an
  # ancestor of it) — shared by :focus-within / :hover / :active. Empty when target nil.
  defp ancestor_chain_match(_candidates, _nodes, nil), do: []

  defp ancestor_chain_match(candidates, nodes, target) do
    chain = MapSet.new([target | Query.ancestors(nodes, target)])
    Enum.filter(candidates, &MapSet.member?(chain, &1))
  end

  # An upgraded custom element carries a definition on its record.
  defp upgraded?(nodes, id) do
    match?(%DOM.NodeData.Element{definition: def} when def != nil, Table.fetch!(nodes, id))
  end

  # The document's :target element for `fragment`: the first element with id==fragment
  # (via the id index), else the first <a name==fragment> in document order, else nil.
  defp target_id(nodes, index, fragment) do
    case Table.index_lookup(index, :id, fragment) do
      [id | _] -> id
      [] -> named_anchor(nodes, fragment)
    end
  end

  defp named_anchor(nodes, fragment) do
    nodes
    |> Table.elements_by_tag_name(Process.get(:document_id), "a")
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
    |> DOM.NodeData.Table.descendant_ids(form)
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
  # (:forward) or end (:backward).
  defp nth(context, candidates, {a, b}, direction) do
    nth_among(candidates, direction, {a, b}, &Query.element_siblings(context, &1))
  end

  # An+B among same-type element siblings (the *-of-type variants).
  defp nth_type(context, candidates, {a, b}, direction) do
    nth_among(candidates, direction, {a, b}, &Query.same_type_siblings(context, &1))
  end

  # Keep each candidate whose 1-based position, within the sibling set produced by
  # `siblings_fun` (reversed for :backward), satisfies An+B.
  defp nth_among(candidates, direction, {a, b}, siblings_fun) do
    Enum.filter(candidates, fn id ->
      siblings = siblings_fun.(id)
      siblings = if direction == :backward, do: Enum.reverse(siblings), else: siblings
      index = Enum.find_index(siblings, &(&1 == id))
      index != nil and anb?(index + 1, a, b)
    end)
  end

  # :nth-*(An+B of S) — index among siblings that also match the selector list S.
  defp nth_of(context, candidates, {a, b}, list, direction) do
    Enum.filter(candidates, fn id ->
      siblings = Query.element_siblings(context, id)
      matching = match_list(list, context, siblings)
      matching = Enum.filter(siblings, &(&1 in matching))
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

  defp match_list(list, context, candidates) do
    list
    |> Enum.flat_map(&DOM.CSS.match(&1, context, candidates))
    |> Enum.uniq()
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
