defmodule DOM.CSS.SerializerTest do
  use ExUnit.Case, async: true

  describe "to_string/1 renders each simple selector" do
    test "type" do
      assert DOM.CSS.to_string([{:compound, [{:type, "div"}]}]) == "div"
    end

    test "universal" do
      assert DOM.CSS.to_string([{:compound, [:universal]}]) == "*"
    end

    test "id" do
      assert DOM.CSS.to_string([{:compound, [{:id, "main"}]}]) == "#main"
    end

    test "class" do
      assert DOM.CSS.to_string([{:compound, [{:class, "box"}]}]) == ".box"
    end

    test "attribute presence" do
      assert DOM.CSS.to_string([{:compound, [{:attr, "disabled"}]}]) == "[disabled]"
    end

    test "attribute with operator" do
      assert DOM.CSS.to_string([{:compound, [{:attr, "href", :prefix, "http"}]}]) ==
               ~s([href^="http"])
    end

    test "attribute with case flag" do
      assert DOM.CSS.to_string([{:compound, [{:attr, "type", :eq, "text", :i}]}]) ==
               ~s([type="text" i])
    end

    test "keyword pseudo-class" do
      assert DOM.CSS.to_string([{:compound, [{:pseudo_class, "hover"}]}]) == ":hover"
    end

    test "nth-child" do
      assert DOM.CSS.to_string([{:compound, [{:pseudo_class, "nth-child", {2, 1}}]}]) ==
               ":nth-child(2n+1)"
    end

    test "negation" do
      assert DOM.CSS.to_string([{:compound, [{:not, [{:compound, [{:class, "box"}]}]}]}]) ==
               ":not(.box)"
    end

    test "pseudo-element" do
      assert DOM.CSS.to_string([{:compound, [{:pseudo_element, "before"}]}]) == "::before"
    end
  end

  describe "to_string/1 renders combinators and lists" do
    test "compound" do
      assert DOM.CSS.to_string([{:compound, [{:type, "a"}, {:id, "m"}, {:class, "b"}]}]) ==
               "a#m.b"
    end

    test "child combinator" do
      complex = [{:compound, [{:type, "ul"}]}, :child, {:compound, [{:type, "li"}]}]
      assert DOM.CSS.to_string([complex]) == "ul > li"
    end

    test "descendant combinator" do
      complex = [{:compound, [{:type, "div"}]}, :descendant, {:compound, [{:class, "box"}]}]
      assert DOM.CSS.to_string([complex]) == "div .box"
    end

    test "selector list" do
      assert DOM.CSS.to_string([{:compound, [{:class, "a"}]}, {:compound, [{:class, "b"}]}]) ==
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
