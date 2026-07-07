defmodule DOM.CSS.MatchTest do
  use ExUnit.Case, async: true

  import CSSTable

  alias DOM.CSS.Type
  alias DOM.CSS.Universal

  # match/3 is unit-tested directly against a hand-built ETS table of NodeData,
  # without a DOM GenServer. Leaf simple selectors are tested by constructing
  # the struct directly (not through parse, which wraps them in a Compound).

  defp matched(table, selector, candidate_ids) do
    DOM.CSS.match(selector, table, candidate_ids) |> MapSet.new()
  end

  describe "type selector" do
    setup do
      {table, ids} =
        build(
          element("root", [], [
            element("a", [], [], as: :a1),
            element("b", [], [element("a", [], [], as: :a2)], as: :b),
            element("a", [], [], as: :a3)
          ])
        )

      candidates = [ids[:a1], ids[:b], ids[:a2], ids[:a3]]
      %{table: table, ids: ids, candidates: candidates}
    end

    test "matches elements with the given local name", ctx do
      assert matched(ctx.table, %Type{name: "a"}, ctx.candidates) ==
               MapSet.new([ctx.ids[:a1], ctx.ids[:a2], ctx.ids[:a3]])
    end

    test "the universal selector matches every element candidate", ctx do
      assert matched(ctx.table, %Universal{}, ctx.candidates) == MapSet.new(ctx.candidates)
    end

    test "returns an empty set when nothing matches", ctx do
      assert matched(ctx.table, %Type{name: "nope"}, ctx.candidates) == MapSet.new()
    end

    test "only considers candidates, not the whole table", ctx do
      assert matched(ctx.table, %Type{name: "a"}, [ctx.ids[:a1]]) == MapSet.new([ctx.ids[:a1]])
    end
  end
end
