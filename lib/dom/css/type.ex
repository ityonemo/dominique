defmodule DOM.CSS.Type do
  @moduledoc "A type selector such as `div`, optionally namespaced."

  alias DOM.CSS.Query
  alias DOM.CSS.Serialize

  @enforce_keys [:name]
  defstruct [:name, namespace: nil]

  use DOM.CSS

  @type t :: %__MODULE__{name: String.t(), namespace: DOM.CSS.namespace() | nil}

  @impl DOM.CSS
  # `|div` (`:none`) targets the null namespace, which no parsed element carries
  # (every element is :html/:svg/:mathml) — so it matches nothing. `*|div`/`div`
  # (`:any`/`nil`) match any namespace.
  def match(%{namespace: :none}, _context, _candidate_ids), do: []

  def match(%{name: name}, %{index: index}, candidate_ids) do
    Query.type(index, candidate_ids, name)
  end

  defimpl String.Chars do
    def to_string(%{name: name, namespace: nil}), do: Serialize.escape_ident(name)

    def to_string(%{name: name, namespace: ns}),
      do: Serialize.ns(ns) <> Serialize.escape_ident(name)
  end
end
