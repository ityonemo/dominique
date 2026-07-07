defmodule DOM.CSS.Serialize do
  @moduledoc false

  # Shared serialization helpers used by the String.Chars implementations of the
  # DOM.CSS.* selector structs. They live here because protocol implementations
  # cannot share private functions.

  @op_strings %{
    eq: "=",
    includes: "~=",
    dash: "|=",
    prefix: "^=",
    suffix: "$=",
    substring: "*="
  }

  @doc "Renders an attribute operator atom to its selector string."
  def op(operator), do: Map.fetch!(@op_strings, operator)

  @doc "Renders a namespace prefix (string | :any | :none) with its trailing `|`."
  def ns(:any), do: "*|"
  def ns(:none), do: "|"
  def ns(prefix), do: escape_ident(prefix) <> "|"

  @doc "Double-quotes an attribute value."
  def quote_value(value), do: "\"" <> value <> "\""

  @doc """
  Re-escapes an identifier so it round-trips: a leading digit is hex-escaped, and
  any character outside `[-_a-zA-Z0-9]` is backslash-escaped.
  """
  def escape_ident(<<digit, rest::binary>>) when digit in ?0..?9 do
    "\\3" <> <<digit>> <> " " <> escape_body(rest)
  end

  def escape_ident(ident), do: escape_body(ident)

  defp escape_body(ident) do
    ident
    |> String.to_charlist()
    |> Enum.map_join(&escape_char/1)
  end

  defp escape_char(char) when char in ?a..?z or char in ?A..?Z or char in ?0..?9, do: <<char>>
  defp escape_char(char) when char in [?-, ?_], do: <<char>>
  defp escape_char(char), do: "\\" <> <<char::utf8>>

  @doc "Renders an An+B pair to its canonical string (e.g. `2n+1`, `-n`, `3`)."
  def anb(0, b), do: Integer.to_string(b)
  def anb(a, 0), do: coeff(a) <> "n"
  def anb(a, b) when b > 0, do: coeff(a) <> "n+" <> Integer.to_string(b)
  def anb(a, b), do: coeff(a) <> "n" <> Integer.to_string(b)

  defp coeff(1), do: ""
  defp coeff(-1), do: "-"
  defp coeff(a), do: Integer.to_string(a)

  @doc "Renders a selector list (list of complex selectors) joined by `, `."
  def selector_list(list), do: Enum.map_join(list, ", ", &Kernel.to_string/1)
end
