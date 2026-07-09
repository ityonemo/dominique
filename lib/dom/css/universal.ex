defmodule DOM.CSS.Universal do
  @moduledoc "The universal selector `*`, optionally namespaced."

  alias DOM.CSS.Query
  alias DOM.CSS.Serialize

  defstruct namespace: nil

  use DOM.CSS

  @type t :: %__MODULE__{namespace: DOM.CSS.namespace() | nil}

  @impl DOM.CSS
  # `|*` (`:none`) targets the null namespace, which no parsed element carries
  # (every element is :html/:svg/:mathml) — so it matches nothing. `*|*`/`*`
  # (`:any`/`nil`) match any namespace.
  def match(%{namespace: :none}, _nodes, _candidate_ids), do: []

  def match(_selector, nodes, candidate_ids) do
    Query.elements(nodes, candidate_ids)
  end

  defimpl String.Chars do
    def to_string(%{namespace: nil}), do: "*"
    def to_string(%{namespace: ns}), do: Serialize.ns(ns) <> "*"
  end
end
