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

    test "attribute dash (|=) matches value or value-prefixed", _ctx do
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

  describe "compound selector" do
    setup do
      {table, ids} =
        build(
          element("root", [], [
            element("a", [{"id", "main"}, {"class", "box"}], [], as: :a),
            element("a", [{"class", "box"}], [], as: :a2),
            element("b", [{"id", "main"}, {"class", "box"}], [], as: :b),
            element("a", [{"class", "other"}], [], as: :a3)
          ])
        )

      candidates = [ids[:a], ids[:a2], ids[:b], ids[:a3]]
      %{table: table, ids: ids, candidates: candidates}
    end

    defp compound(selector), do: selector |> DOM.CSS.parse() |> hd()

    test "intersects its simple selectors", ctx do
      assert matched(ctx.table, compound("a.box"), ctx.candidates) ==
               MapSet.new([ctx.ids[:a], ctx.ids[:a2]])
    end

    test "type, id, and class together", ctx do
      assert matched(ctx.table, compound("a.box#main"), ctx.candidates) ==
               MapSet.new([ctx.ids[:a]])
    end

    test "universal plus class", ctx do
      assert matched(ctx.table, compound("*.box"), ctx.candidates) ==
               MapSet.new([ctx.ids[:a], ctx.ids[:a2], ctx.ids[:b]])
    end

    test "no candidate satisfies all parts", ctx do
      assert matched(ctx.table, compound("b.other"), ctx.candidates) == MapSet.new()
    end
  end

  describe "combinators" do
    # section > ul > li.item  and siblings:  h1 + p , h1 ~ p
    setup do
      {table, ids} =
        build(
          element(
            "section",
            [],
            [
              element("h1", [], [], as: :h1),
              element(
                "ul",
                [],
                [
                  element("li", [{"class", "item"}], [], as: :li1),
                  element("li", [{"class", "item"}], [element("span", [], [], as: :span)],
                    as: :li2
                  )
                ],
                as: :ul
              ),
              element("p", [], [], as: :p1),
              element("p", [], [], as: :p2)
            ],
            as: :section
          )
        )

      all = for i <- 0..8, do: ids[i]
      %{table: table, ids: ids, all: all}
    end

    defp complex(selector), do: selector |> DOM.CSS.parse() |> hd()

    test "child combinator", ctx do
      assert matched(ctx.table, complex("ul > li"), ctx.all) ==
               MapSet.new([ctx.ids[:li1], ctx.ids[:li2]])
    end

    test "child combinator does not match grandchildren", ctx do
      assert matched(ctx.table, complex("section > li"), ctx.all) == MapSet.new()
    end

    test "descendant combinator matches at any depth", ctx do
      assert matched(ctx.table, complex("section span"), ctx.all) == MapSet.new([ctx.ids[:span]])
    end

    test "descendant chained with child", ctx do
      assert matched(ctx.table, complex("section li.item"), ctx.all) ==
               MapSet.new([ctx.ids[:li1], ctx.ids[:li2]])
    end

    test "next-sibling combinator matches only the immediate sibling", ctx do
      assert matched(ctx.table, complex("ul + p"), ctx.all) == MapSet.new([ctx.ids[:p1]])
    end

    test "subsequent-sibling combinator matches all following siblings", ctx do
      assert matched(ctx.table, complex("h1 ~ p"), ctx.all) ==
               MapSet.new([ctx.ids[:p1], ctx.ids[:p2]])
    end

    test "three-part chain", ctx do
      assert matched(ctx.table, complex("section > ul > li"), ctx.all) ==
               MapSet.new([ctx.ids[:li1], ctx.ids[:li2]])
    end
  end

  describe "structural pseudo-classes" do
    setup do
      {table, ids} =
        build(
          element(
            "ul",
            [],
            [
              element("li", [{"class", "a"}], [], as: :li1),
              element("li", [{"class", "b"}], [], as: :li2),
              element("li", [{"class", "a"}], [], as: :li3),
              element("li", [{"class", "b"}], [], as: :li4)
            ],
            as: :ul
          )
        )

      lis = [ids[:li1], ids[:li2], ids[:li3], ids[:li4]]
      %{table: table, ids: ids, lis: lis, all: [ids[:ul] | lis]}
    end

    defp pc(selector), do: selector |> DOM.CSS.parse() |> hd()

    test ":first-child", ctx do
      assert matched(ctx.table, pc("li:first-child"), ctx.lis) == MapSet.new([ctx.ids[:li1]])
    end

    test ":last-child", ctx do
      assert matched(ctx.table, pc("li:last-child"), ctx.lis) == MapSet.new([ctx.ids[:li4]])
    end

    test ":only-child (none, since ul has four)", ctx do
      assert matched(ctx.table, pc("li:only-child"), ctx.lis) == MapSet.new()
    end

    test ":nth-child(2n) selects even positions", ctx do
      assert matched(ctx.table, pc("li:nth-child(2n)"), ctx.lis) ==
               MapSet.new([ctx.ids[:li2], ctx.ids[:li4]])
    end

    test ":nth-child(odd) selects odd positions", ctx do
      assert matched(ctx.table, pc("li:nth-child(odd)"), ctx.lis) ==
               MapSet.new([ctx.ids[:li1], ctx.ids[:li3]])
    end

    test ":nth-child(2) selects the second", ctx do
      assert matched(ctx.table, pc("li:nth-child(2)"), ctx.lis) == MapSet.new([ctx.ids[:li2]])
    end

    test ":nth-last-child(1) selects the last", ctx do
      assert matched(ctx.table, pc("li:nth-last-child(1)"), ctx.lis) ==
               MapSet.new([ctx.ids[:li4]])
    end

    test ":nth-child(An+B of S) counts only matching siblings", ctx do
      # among .a siblings (li1, li3), the 2nd is li3
      assert matched(ctx.table, pc("li:nth-child(2 of .a)"), ctx.lis) ==
               MapSet.new([ctx.ids[:li3]])
    end

    test ":root matches the element whose parent is not an element", ctx do
      assert matched(ctx.table, pc(":root"), ctx.all) == MapSet.new([ctx.ids[:ul]])
    end

    test ":empty matches childless elements", ctx do
      assert matched(ctx.table, pc("li:empty"), ctx.all) == MapSet.new(ctx.lis)
      assert matched(ctx.table, pc("ul:empty"), ctx.all) == MapSet.new()
    end

    test ":not negates", ctx do
      assert matched(ctx.table, pc("li:not(.a)"), ctx.lis) ==
               MapSet.new([ctx.ids[:li2], ctx.ids[:li4]])
    end

    test ":is unions", ctx do
      assert matched(ctx.table, pc("li:is(.a, :last-child)"), ctx.lis) ==
               MapSet.new([ctx.ids[:li1], ctx.ids[:li3], ctx.ids[:li4]])
    end

    test ":where behaves like :is", ctx do
      assert matched(ctx.table, pc("li:where(.b)"), ctx.lis) ==
               MapSet.new([ctx.ids[:li2], ctx.ids[:li4]])
    end

    test "unsupported UI pseudo-class matches nothing", ctx do
      assert matched(ctx.table, pc("li:hover"), ctx.lis) == MapSet.new()
    end
  end

  describe ":has" do
    setup do
      {table, ids} =
        build(
          element(
            "root",
            [],
            [
              element("div", [], [element("img", [], [], as: :img)], as: :with_img),
              element("div", [], [element("p", [], [], as: :p)], as: :with_p),
              element("div", [], [], as: :empty_div)
            ],
            as: :root
          )
        )

      divs = [ids[:with_img], ids[:with_p], ids[:empty_div]]
      %{table: table, ids: ids, divs: divs}
    end

    defp has(selector), do: selector |> DOM.CSS.parse() |> hd()

    test ":has with a descendant", ctx do
      assert matched(ctx.table, has("div:has(img)"), ctx.divs) ==
               MapSet.new([ctx.ids[:with_img]])
    end

    test ":has with a child combinator", ctx do
      assert matched(ctx.table, has("div:has(> p)"), ctx.divs) ==
               MapSet.new([ctx.ids[:with_p]])
    end
  end

  describe "pseudo-element" do
    test "never matches an element" do
      {table, ids} = build(element("p", [], [], as: :p))
      assert DOM.CSS.match(pc("p::before"), table, [ids[:p]]) == []
    end
  end
end
