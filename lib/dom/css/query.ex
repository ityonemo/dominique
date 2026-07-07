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

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp select(nodes, spec), do: :ets.select(nodes, spec)

  # Keep only candidates that the spec matched, preserving candidate order.
  defp intersect(matched, candidates) do
    set = MapSet.new(matched)
    Enum.filter(candidates, &MapSet.member?(set, &1))
  end
end
