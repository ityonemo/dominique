defmodule HTML5lib do
  @moduledoc """
  Loader for the vendored html5lib-tests tokenizer conformance suite
  (`test/_html5lib/tokenizer/*.test`, plain JSON). Reads the applicable cases and
  converts our `DOM.HTML.Token.*` structs to html5lib's array token form so a
  test can assert equality.

  DEFERRED categories are skipped (`applicable?/1`): cases with parse `errors`
  (we do no error recovery), with a non-default `initialStates` (the spec's
  content-model mode switching, which our grammar bakes into per-element rules),
  and `doubleEscaped` cases. Entity-dependent cases are skipped via a description
  skip-list, since we leave character references undecoded.
  """

  alias DOM.HTML.Token

  @dir "test/_html5lib/tokenizer"

  @doc "The applicable cases in `filename` (e.g. \"test1.test\"), as maps."
  def cases(filename) do
    @dir
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("tests")
    |> Enum.filter(&applicable?/1)
  end

  # A case we can run in the Data state with no entity decoding or error recovery.
  defp applicable?(test) do
    not Map.has_key?(test, "errors") and
      not Map.has_key?(test, "doubleEscaped") and
      default_state?(Map.get(test, "initialStates")) and
      not needs_entities?(test)
  end

  defp default_state?(nil), do: true
  defp default_state?(["Data state"]), do: true
  defp default_state?(_other), do: false

  # Heuristic: skip cases whose input contains a character reference, since we
  # leave entities undecoded and the expected output assumes decoding.
  defp needs_entities?(%{"input" => input}), do: String.contains?(input, "&")

  @doc "Converts our token list to html5lib's array form for comparison."
  def to_html5lib(tokens), do: Enum.map(tokens, &token_to_array/1)

  defp token_to_array(%Token.Character{data: data}), do: ["Character", data]
  defp token_to_array(%Token.Comment{data: data}), do: ["Comment", data]
  defp token_to_array(%Token.EndTag{name: name}), do: ["EndTag", name]

  defp token_to_array(%Token.StartTag{name: name, attributes: attrs, self_closing: sc}) do
    base = ["StartTag", name, Map.new(attrs)]
    if sc, do: base ++ [true], else: base
  end

  defp token_to_array(%Token.Doctype{} = d) do
    ["DOCTYPE", d.name, d.public_id, d.system_id, not d.force_quirks]
  end

  @doc """
  html5lib emits one Character token per character; we coalesce. Merge adjacent
  `["Character", _]` entries in an *expected* output so it lines up with ours.
  """
  def coalesce_characters(output) do
    Enum.reduce(output, [], fn
      ["Character", data], [["Character", prev] | rest] -> [["Character", prev <> data] | rest]
      token, acc -> [token | acc]
    end)
    |> Enum.reverse()
  end
end
