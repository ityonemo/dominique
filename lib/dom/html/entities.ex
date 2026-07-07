defmodule DOM.HTML.Entities do
  @moduledoc """
  Character-reference decoding for HTML text and attribute values. Resolves
  numeric references (`&#38;`, `&#x26;`) and named references against the WHATWG
  named-character-reference table (`priv/html/entities.json`, vendored), using
  longest match. Named references may or may not end in `;` (a legacy subset is
  valid without one).

  `decode/1` is a pure `String.t -> String.t` transform; `DOM.HTML.Token.decode/1`
  applies it to the text-bearing fields of each token.
  """

  @external_resource Path.join(:code.priv_dir(:dominique), "html/entities.json")

  # name (without leading "&", with any trailing ";") => replacement characters.
  @table :dominique
         |> :code.priv_dir()
         |> Path.join("html/entities.json")
         |> File.read!()
         |> JSON.decode!()
         |> Map.new(fn {"&" <> name, %{"characters" => chars}} -> {name, chars} end)

  # The longest entity-name length, to bound the longest-match scan.
  @max_name_length @table |> Map.keys() |> Enum.map(&byte_size/1) |> Enum.max()

  @doc """
  Decodes all character references in text. Pass `attribute: true` for attribute
  values, where a semicolon-less named reference followed by `=` or an
  alphanumeric is left literal (per the WHATWG attribute exception).
  """
  @spec decode(String.t(), keyword()) :: String.t()
  def decode(string, opts \\ []), do: decode(string, Keyword.get(opts, :attribute, false), [])

  # Walk the string, copying runs verbatim and resolving each `&`-reference.
  defp decode(<<>>, _attr?, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode(<<?&, rest::binary>>, attr?, acc) do
    {replacement, rest} = reference(rest, attr?)
    decode(rest, attr?, [replacement | acc])
  end

  defp decode(<<char::utf8, rest::binary>>, attr?, acc) do
    decode(rest, attr?, [<<char::utf8>> | acc])
  end

  # A stray byte that is not valid UTF-8 on its own is copied verbatim.
  defp decode(<<byte, rest::binary>>, attr?, acc) do
    decode(rest, attr?, [<<byte>> | acc])
  end

  # A reference begins just after `&`. Numeric: `#...`. Named: a table entry.
  # An unrecognized `&` is left literal.
  defp reference(<<?#, x, rest::binary>>, _attr?) when x in [?x, ?X] do
    numeric(rest, 16, &hex_digit?/1)
  end

  defp reference(<<?#, rest::binary>>, _attr?) do
    numeric(rest, 10, &dec_digit?/1)
  end

  defp reference(rest, attr?), do: named(rest, attr?)

  # Numeric reference: consume the digits, resolve the code point, drop one
  # trailing `;`. An empty digit run leaves the `&#` literal.
  defp numeric(rest, base, digit?) do
    {digits, rest} = take_while(rest, digit?)

    if digits == "" do
      {prefix(base), rest}
    else
      code = String.to_integer(digits, base)
      {<<code::utf8>>, drop_semicolon(rest)}
    end
  end

  defp prefix(16), do: "&#x"
  defp prefix(10), do: "&#"

  # Named reference: longest match against the table over the candidate name
  # (letters/digits, then an optional `;`). Falls back to a literal `&`.
  defp named(rest, attr?) do
    candidate = String.slice(rest, 0, @max_name_length)
    resolve(candidate, rest, attr?)
  end

  defp resolve("", rest, _attr?), do: {"&", rest}

  defp resolve(candidate, rest, attr?) do
    if chars = Map.get(@table, candidate) do
      after_name = binary_part(rest, byte_size(candidate), byte_size(rest) - byte_size(candidate))

      if attribute_exception?(candidate, after_name, attr?) do
        {"&", rest}
      else
        {chars, after_name}
      end
    else
      resolve(String.slice(candidate, 0..-2//1), rest, attr?)
    end
  end

  # In an attribute value, a semicolon-less named reference followed by `=` or an
  # alphanumeric is not a reference (legacy `?a=1&lang=en` URLs stay intact).
  defp attribute_exception?(candidate, after_name, true) do
    not String.ends_with?(candidate, ";") and
      match?(
        <<c, _::binary>> when c == ?= or c in ?0..?9 or c in ?a..?z or c in ?A..?Z,
        after_name
      )
  end

  defp attribute_exception?(_candidate, _after_name, false), do: false

  defp take_while(binary, pred), do: take_while(binary, pred, [])

  defp take_while(<<char, rest::binary>>, pred, acc) do
    if pred.(char),
      do: take_while(rest, pred, [char | acc]),
      else: {done(acc), <<char, rest::binary>>}
  end

  defp take_while(<<>>, _pred, acc), do: {done(acc), <<>>}

  defp done(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp drop_semicolon(<<?;, rest::binary>>), do: rest
  defp drop_semicolon(rest), do: rest

  defp dec_digit?(c), do: c in ?0..?9
  defp hex_digit?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F
end
