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

  # :scope — the scoping root of the query. `query_ids`/`matches` bind the
  # concrete root id into the arg before matching (DOM.CSS.bind_scope/2); an
  # unbound :scope (arg nil) has no root and matches nothing.
  def match(%{name: "scope", arg: {:scope, scope_id}}, _context, candidates) do
    Enum.filter(candidates, &(&1 == scope_id))
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
