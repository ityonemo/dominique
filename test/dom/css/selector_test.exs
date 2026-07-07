defmodule DOM.CSS.SelectorTest do
  use ExUnit.Case, async: true

  describe "simple selectors" do
    test "type selector" do
      assert DOM.CSS.parse("div") == [{:compound, [{:type, "div"}]}]
    end

    test "universal selector" do
      assert DOM.CSS.parse("*") == [{:compound, [:universal]}]
    end

    test "id selector" do
      assert DOM.CSS.parse("#main") == [{:compound, [{:id, "main"}]}]
    end

    test "class selector" do
      assert DOM.CSS.parse(".box") == [{:compound, [{:class, "box"}]}]
    end
  end

  describe "names" do
    test "accepts hyphens, underscores, and digits after the first character" do
      assert DOM.CSS.parse("data-item_2") == [{:compound, [{:type, "data-item_2"}]}]
      assert DOM.CSS.parse(".is-active_1") == [{:compound, [{:class, "is-active_1"}]}]
    end
  end

  describe "attribute selectors" do
    test "presence" do
      assert DOM.CSS.parse("[disabled]") == [{:compound, [{:attr, "disabled"}]}]
    end

    test "equals with unquoted value" do
      assert DOM.CSS.parse("[type=text]") == [{:compound, [{:attr, "type", :eq, "text"}]}]
    end

    test "equals with double-quoted value" do
      assert DOM.CSS.parse(~s([type="text"])) == [{:compound, [{:attr, "type", :eq, "text"}]}]
    end

    test "equals with single-quoted value" do
      assert DOM.CSS.parse("[type='text']") == [{:compound, [{:attr, "type", :eq, "text"}]}]
    end

    test "includes operator ~=" do
      assert DOM.CSS.parse("[class~=box]") == [{:compound, [{:attr, "class", :includes, "box"}]}]
    end

    test "dash operator |=" do
      assert DOM.CSS.parse("[lang|=en]") == [{:compound, [{:attr, "lang", :dash, "en"}]}]
    end

    test "prefix operator ^=" do
      assert DOM.CSS.parse("[href^=http]") == [{:compound, [{:attr, "href", :prefix, "http"}]}]
    end

    test "suffix operator $= with a quoted value" do
      assert DOM.CSS.parse(~s([src$=".png"])) == [{:compound, [{:attr, "src", :suffix, ".png"}]}]
    end

    test "substring operator *=" do
      assert DOM.CSS.parse("[title*=hello]") ==
               [{:compound, [{:attr, "title", :substring, "hello"}]}]
    end

    test "case-insensitive flag" do
      assert DOM.CSS.parse("[type=text i]") == [{:compound, [{:attr, "type", :eq, "text", :i}]}]
    end

    test "case-sensitive flag" do
      assert DOM.CSS.parse("[type=text s]") == [{:compound, [{:attr, "type", :eq, "text", :s}]}]
    end

    test "combines with other simple selectors in a compound" do
      assert DOM.CSS.parse("a[href^=http].external") ==
               [
                 {:compound,
                  [{:type, "a"}, {:attr, "href", :prefix, "http"}, {:class, "external"}]}
               ]
    end
  end

  describe "compound selectors" do
    test "type with id and class" do
      assert DOM.CSS.parse("a#main.box") ==
               [{:compound, [{:type, "a"}, {:id, "main"}, {:class, "box"}]}]
    end

    test "universal with class" do
      assert DOM.CSS.parse("*.box") == [{:compound, [:universal, {:class, "box"}]}]
    end
  end

  describe "combinators" do
    test "descendant combinator (whitespace)" do
      assert DOM.CSS.parse("div .box") ==
               [[{:compound, [{:type, "div"}]}, :descendant, {:compound, [{:class, "box"}]}]]
    end

    test "child combinator" do
      assert DOM.CSS.parse("ul > li") ==
               [[{:compound, [{:type, "ul"}]}, :child, {:compound, [{:type, "li"}]}]]
    end

    test "next-sibling combinator" do
      assert DOM.CSS.parse("h1 + p") ==
               [[{:compound, [{:type, "h1"}]}, :next_sibling, {:compound, [{:type, "p"}]}]]
    end

    test "subsequent-sibling combinator" do
      assert DOM.CSS.parse("h1 ~ p") ==
               [[{:compound, [{:type, "h1"}]}, :subsequent_sibling, {:compound, [{:type, "p"}]}]]
    end

    test "child combinator without surrounding whitespace" do
      assert DOM.CSS.parse("ul>li") ==
               [[{:compound, [{:type, "ul"}]}, :child, {:compound, [{:type, "li"}]}]]
    end

    test "chained combinators" do
      assert DOM.CSS.parse("section > ul li") ==
               [
                 [
                   {:compound, [{:type, "section"}]},
                   :child,
                   {:compound, [{:type, "ul"}]},
                   :descendant,
                   {:compound, [{:type, "li"}]}
                 ]
               ]
    end
  end

  describe "selector lists" do
    test "comma-separated compounds" do
      assert DOM.CSS.parse(".a, .b") ==
               [{:compound, [{:class, "a"}]}, {:compound, [{:class, "b"}]}]
    end

    test "comma-separated complex selectors" do
      assert DOM.CSS.parse("div > a, .box") ==
               [
                 [{:compound, [{:type, "div"}]}, :child, {:compound, [{:type, "a"}]}],
                 {:compound, [{:class, "box"}]}
               ]
    end
  end

  describe "invalid selectors" do
    test "raises on an empty selector" do
      assert_raise ArgumentError, fn -> DOM.CSS.parse("") end
    end

    test "raises on trailing garbage" do
      assert_raise ArgumentError, fn -> DOM.CSS.parse("div !") end
    end
  end
end
