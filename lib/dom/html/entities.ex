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
    numeric(rest, 16, &hex_digit?/1, <<?#, x>>)
  end

  defp reference(<<?#, rest::binary>>, _attr?) do
    numeric(rest, 10, &dec_digit?/1, "#")
  end

  defp reference(rest, attr?), do: named(rest, attr?)

  # Numeric reference: consume the digits, resolve the code point (with the
  # WHATWG numeric-character-reference-end-state fixups), drop one trailing `;`.
  # An empty digit run leaves the `&` + the consumed prefix literal.
  defp numeric(rest, base, digit?, prefix) do
    {digits, rest} = take_while(rest, digit?)

    if digits == "" do
      {"&" <> prefix, rest}
    else
      code = String.to_integer(digits, base)
      {<<numeric_codepoint(code)::utf8>>, drop_semicolon(rest)}
    end
  end

  # C1 control (0x80–0x9F) -> Windows-1252 code point mappings (WHATWG table).
  @c1_replacements %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  # WHATWG "numeric character reference end state" replacements: NULL, out-of-
  # range, and surrogates become U+FFFD; the C1 controls (0x80–0x9F) map to their
  # Windows-1252 equivalents.
  defp numeric_codepoint(0), do: 0xFFFD
  defp numeric_codepoint(code) when code > 0x10FFFF, do: 0xFFFD
  defp numeric_codepoint(code) when code in 0xD800..0xDFFF, do: 0xFFFD

  defp numeric_codepoint(code) when is_map_key(@c1_replacements, code),
    do: Map.fetch!(@c1_replacements, code)

  defp numeric_codepoint(code), do: code

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
