defmodule DOM.CSS.Attribute do
  @moduledoc """
  An attribute selector: presence `[a]`, value match `[a op v]`, an optional
  case flag `[a op v i]`, and an optional namespace `[ns|a]`.
  """

  alias DOM.CSS.Query
  alias DOM.CSS.Serialize

  @enforce_keys [:name]
  defstruct [:name, namespace: nil, op: nil, value: nil, flag: nil]

  use DOM.CSS

  @type t :: %__MODULE__{
          name: String.t(),
          namespace: DOM.CSS.namespace() | nil,
          op: DOM.CSS.attr_op() | nil,
          value: String.t() | nil,
          flag: :i | :s | nil
        }

  @impl DOM.CSS
  def match(%{name: name, op: op, value: value, flag: flag}, %{nodes: nodes}, candidate_ids) do
    Query.attribute(nodes, candidate_ids, name, op, value, flag)
  end

  defimpl String.Chars do
    def to_string(%{name: name, namespace: ns, op: op, value: value, flag: flag}) do
      "[" <> prefix(ns) <> Serialize.escape_ident(name) <> match(op, value, flag) <> "]"
    end

    defp prefix(nil), do: ""
    defp prefix(ns), do: Serialize.ns(ns)

    defp match(nil, _value, _flag), do: ""
    defp match(op, value, nil), do: Serialize.op(op) <> Serialize.quote_value(value)

    defp match(op, value, flag) do
      Serialize.op(op) <> Serialize.quote_value(value) <> " " <> Atom.to_string(flag)
    end
  end
end
