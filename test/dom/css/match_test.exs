defmodule DOM.CSS.MatchTest do
  use ExUnit.Case, async: true

  import CSSTable

  alias DOM.CSS.Attribute
  alias DOM.CSS.Class
  alias DOM.CSS.Id
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

  describe "id, class, attribute" do
    setup do
      {table, ids} =
        build(
          element("root", [], [
            element("a", [{"id", "main"}, {"class", "box highlight"}], [], as: :a),
            element("b", [{"class", "box"}], [], as: :b),
            element("c", [{"data-role", "nav"}, {"href", "https://x"}], [], as: :c),
            element("d", [], [], as: :d)
          ])
        )

      candidates = [ids[:a], ids[:b], ids[:c], ids[:d]]
      %{table: table, ids: ids, candidates: candidates}
    end

    test "id selector", ctx do
      assert matched(ctx.table, %Id{name: "main"}, ctx.candidates) == MapSet.new([ctx.ids[:a]])
    end

    test "class selector matches any element carrying the token", ctx do
      assert matched(ctx.table, %Class{name: "box"}, ctx.candidates) ==
               MapSet.new([ctx.ids[:a], ctx.ids[:b]])
    end

    test "attribute presence", ctx do
      assert matched(ctx.table, %Attribute{name: "data-role"}, ctx.candidates) ==
               MapSet.new([ctx.ids[:c]])
    end

    test "attribute exact equals", ctx do
      assert matched(
               ctx.table,
               %Attribute{name: "data-role", op: :eq, value: "nav"},
               ctx.candidates
             ) ==
               MapSet.new([ctx.ids[:c]])
    end

    test "attribute includes (~=) matches a whitespace token", ctx do
      assert matched(
               ctx.table,
               %Attribute{name: "class", op: :includes, value: "highlight"},
               ctx.candidates
             ) ==
               MapSet.new([ctx.ids[:a]])
    end

    test "attribute dash (|=) matches value or value-prefixed", ctx do
      {table, ids} =
        build(element("root", [], [element("p", [{"lang", "en-US"}], [], as: :p)]))

      assert matched(table, %Attribute{name: "lang", op: :dash, value: "en"}, [ids[:p]]) ==
               MapSet.new([ids[:p]])
    end

    test "attribute prefix/suffix/substring", ctx do
      assert matched(
               ctx.table,
               %Attribute{name: "href", op: :prefix, value: "https"},
               ctx.candidates
             ) ==
               MapSet.new([ctx.ids[:c]])

      assert matched(ctx.table, %Attribute{name: "href", op: :suffix, value: "x"}, ctx.candidates) ==
               MapSet.new([ctx.ids[:c]])

      assert matched(
               ctx.table,
               %Attribute{name: "href", op: :substring, value: "://"},
               ctx.candidates
             ) ==
               MapSet.new([ctx.ids[:c]])
    end

    test "case-insensitive flag on an attribute value", ctx do
      assert matched(
               ctx.table,
               %Attribute{name: "data-role", op: :eq, value: "NAV", flag: :i},
               ctx.candidates
             ) ==
               MapSet.new([ctx.ids[:c]])
    end
  end
end
