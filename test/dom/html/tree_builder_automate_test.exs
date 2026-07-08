defmodule DOM.HTML.TreeBuilderAutomateTest do
  use ExUnit.Case, async: true

  # Data-driven from the vendored html5lib tree-construction .dat suite. One test
  # per applicable case: parse the input, serialize the tree to the .dat
  # #document outline, assert it equals the expected block. See HTML5libTree for
  # the .dat parser and applicability gating, DatOutline for the serializer.
  #
  # Tiered: @files lists the .dat files whose behavior the current tier covers.

  @files ~w(doctype01.dat comments01.dat entities01.dat tests1.dat
            tests2.dat tests4.dat tests15.dat tests17.dat inbody01.dat
            tables01.dat adoption01.dat adoption02.dat tests8.dat tricky01.dat
            webkit02.dat tests9.dat tests10.dat math.dat svg.dat
            tests6.dat tests7.dat tests_innerHTML_1.dat tests16.dat tests19.dat
            template.dat)

  for file <- @files do
    for c <- HTML5libTree.cases(file) do
      @input c.input
      @expected c.document
      @description "#{file}[#{c.index}]: #{c.input |> String.split("\n") |> hd() |> String.slice(0, 60)}"
      @tag :"tree_#{file}"

      if is_nil(c.fragment_context) do
        test @description do
          actual = @input |> DOM.HTML.parse() |> DatOutline.serialize()
          assert actual == @expected
        end
      else
        @context c.fragment_context

        test "fragment " <> @description do
          actual = @input |> DOM.HTML.parse_fragment(@context) |> DatOutline.serialize_fragment()
          assert actual == @expected
        end
      end
    end
  end
end
