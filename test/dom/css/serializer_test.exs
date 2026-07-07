defmodule DOM.CSS.SerializerTest do
  use ExUnit.Case, async: true

  alias DOM.CSS.Attribute
  alias DOM.CSS.Class
  alias DOM.CSS.Complex
  alias DOM.CSS.Compound
  alias DOM.CSS.Id
  alias DOM.CSS.PseudoClass
  alias DOM.CSS.PseudoElement
  alias DOM.CSS.Type
  alias DOM.CSS.Universal

  describe "to_string/1 renders each simple selector" do
    test "type" do
      assert DOM.CSS.to_string([%Compound{simples: [%Type{name: "div"}]}]) == "div"
    end

    test "universal" do
      assert DOM.CSS.to_string([%Compound{simples: [%Universal{}]}]) == "*"
    end

    test "id" do
      assert DOM.CSS.to_string([%Compound{simples: [%Id{name: "main"}]}]) == "#main"
    end

    test "class" do
      assert DOM.CSS.to_string([%Compound{simples: [%Class{name: "box"}]}]) == ".box"
    end

    test "attribute presence" do
      assert DOM.CSS.to_string([%Compound{simples: [%Attribute{name: "disabled"}]}]) ==
               "[disabled]"
    end

    test "attribute with operator" do
      assert DOM.CSS.to_string([
               %Compound{simples: [%Attribute{name: "href", op: :prefix, value: "http"}]}
             ]) ==
               ~s([href^="http"])
    end

    test "attribute with case flag" do
      assert DOM.CSS.to_string([
               %Compound{simples: [%Attribute{name: "type", op: :eq, value: "text", flag: :i}]}
             ]) ==
               ~s([type="text" i])
    end

    test "keyword pseudo-class" do
      assert DOM.CSS.to_string([%Compound{simples: [%PseudoClass{name: "hover"}]}]) == ":hover"
    end

    test "nth-child" do
      assert DOM.CSS.to_string([
               %Compound{simples: [%PseudoClass{name: "nth-child", arg: {2, 1}}]}
             ]) ==
               ":nth-child(2n+1)"
    end

    test "negation" do
      assert DOM.CSS.to_string([
               %Compound{
                 simples: [
                   %PseudoClass{
                     name: "not",
                     arg: {:selector_list, [%Compound{simples: [%Class{name: "box"}]}]}
                   }
                 ]
               }
             ]) ==
               ":not(.box)"
    end

    test "pseudo-element" do
      assert DOM.CSS.to_string([%Compound{simples: [%PseudoElement{name: "before"}]}]) ==
               "::before"
    end
  end

  describe "to_string/1 renders combinators and lists" do
    test "compound" do
      assert DOM.CSS.to_string([
               %Compound{simples: [%Type{name: "a"}, %Id{name: "m"}, %Class{name: "b"}]}
             ]) ==
               "a#m.b"
    end

    test "child combinator" do
      complex = %Complex{
        parts: [
          %Compound{simples: [%Type{name: "ul"}]},
          :child,
          %Compound{simples: [%Type{name: "li"}]}
        ]
      }

      assert DOM.CSS.to_string([complex]) == "ul > li"
    end

    test "descendant combinator" do
      complex = %Complex{
        parts: [
          %Compound{simples: [%Type{name: "div"}]},
          :descendant,
          %Compound{simples: [%Class{name: "box"}]}
        ]
      }

      assert DOM.CSS.to_string([complex]) == "div .box"
    end

    test "selector list" do
      assert DOM.CSS.to_string([
               %Compound{simples: [%Class{name: "a"}]},
               %Compound{simples: [%Class{name: "b"}]}
             ]) ==
               ".a, .b"
    end
  end

  describe "round-trip parse |> to_string |> parse" do
    for selector <- [
          "div",
          "*",
          "#main",
          ".box",
          "a#main.box",
          "svg|rect",
          "*|div",
          "|div",
          "svg|*",
          "[svg|href]",
          "[disabled]",
          ~s([type="text"]),
          "[class~=box]",
          ~s([type="text" i]),
          ":first-child",
          ":nth-child(2n+1)",
          ":nth-child(odd)",
          ":nth-child(2n+1 of .item)",
          ":nth-child(odd of .a, #b)",
          ":not(.a, #b)",
          ":is(.a, #b)",
          ":where(a.x)",
          ":has(> .child)",
          ":has(+ p, .x)",
          ":lang(en, fr)",
          ":dir(ltr)",
          ~S(.foo\.bar),
          "::before",
          "ul > li",
          "div .box",
          "h1 + p",
          "h1 ~ p",
          "section > ul li",
          ".a, .b",
          "div > a, .box"
        ] do
      test "round-trips #{selector}" do
        ast = DOM.CSS.parse(unquote(selector))
        assert DOM.CSS.parse(DOM.CSS.to_string(ast)) == ast
      end
    end
  end
end
