defmodule HTML5libTree do
  @moduledoc """
  Loader for the vendored html5lib tree-construction suite
  (`test/_html5lib/tree-construction/*.dat`), recovered from html5lib-tests
  commit 9329e646 (the last before the tests moved to WPT).

  The `.dat` format is line-oriented, one test per block, sections keyed on
  `#`-markers: `#data` (input HTML), `#errors` / `#new-errors` (ignored — we do
  no error reporting), optional `#document-fragment` (context element for
  fragment parsing), optional `#script-off`/`#script-on`, and `#document` (the
  expected tree as a `| `-indented outline). Tests are separated by a blank line.

  `cases/1` returns the applicable cases as maps; `applicable?/2` gates the
  categories not yet supported by the current tier (fragment, foreign content).
  """

  @dir "test/_html5lib/tree-construction"

  @doc "All cases in `filename` (e.g. \"tests1.dat\") as maps."
  def cases(filename) do
    @dir
    |> Path.join(filename)
    |> File.read!()
    |> split_tests()
    |> Enum.map(&parse_test/1)
    |> Enum.with_index()
    |> Enum.map(fn {test, index} -> Map.put(test, :index, index) end)
  end

  @doc """
  Whether a case is runnable at the given tier. Whole-document parsing skips only
  fragment cases (`#document-fragment`); foreign content (svg/math) is supported.
  """
  def applicable?(test, :whole_document) do
    is_nil(test.fragment_context)
  end

  # A test block ends at "\n\n#data" (the blank line before the next test). We
  # split on that boundary rather than any blank line, since text/comment content
  # can itself contain blank lines.
  defp split_tests(content) do
    content
    |> String.split(~r/\n\n(?=#data\n)/)
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Parse one test block into %{input, document, fragment_context, script}.
  defp parse_test(block) do
    lines = String.split(block, "\n")
    sections = sections(lines)

    %{
      input: sections |> Map.fetch!("#data") |> Enum.join("\n"),
      document: sections |> Map.fetch!("#document") |> Enum.join("\n"),
      fragment_context: fragment_context(sections),
      script: script(sections)
    }
  end

  @markers ~w(#data #errors #new-errors #document #document-fragment #script-off #script-on)

  # Group the lines under their preceding `#`-marker, in source order.
  defp sections(lines) do
    lines
    |> collect(nil, %{})
    |> Map.new(fn {marker, acc} -> {marker, Enum.reverse(acc)} end)
  end

  defp collect([], _marker, acc), do: acc

  defp collect([line | rest], _marker, acc) when line in @markers do
    collect(rest, line, Map.put_new(acc, line, []))
  end

  defp collect([line | rest], marker, acc) when not is_nil(marker) do
    collect(rest, marker, Map.update!(acc, marker, &[line | &1]))
  end

  defp fragment_context(sections) do
    case Map.get(sections, "#document-fragment") do
      [context | _] -> context
      _ -> nil
    end
  end

  defp script(sections) do
    cond do
      Map.has_key?(sections, "#script-off") -> :off
      Map.has_key?(sections, "#script-on") -> :on
      :else -> :both
    end
  end
end
