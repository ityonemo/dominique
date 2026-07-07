defmodule DOM.CSS.Type do
  @moduledoc "A type selector such as `div`, optionally namespaced."

  alias DOM.CSS.Serialize

  @enforce_keys [:name]
  defstruct [:name, namespace: nil]

  use DOM.CSS

  @type t :: %__MODULE__{name: String.t(), namespace: DOM.CSS.namespace() | nil}

  @impl DOM.CSS
  def match(_selector, _nodes, _candidate_ids), do: raise("unimplemented")

  defimpl String.Chars do
    def to_string(%{name: name, namespace: nil}), do: Serialize.escape_ident(name)

    def to_string(%{name: name, namespace: ns}),
      do: Serialize.ns(ns) <> Serialize.escape_ident(name)
  end
end
