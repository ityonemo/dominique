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

    test "decodes a character escape in a class name" do
      assert DOM.CSS.parse(~S(.foo\.bar)) == [{:compound, [{:class, "foo.bar"}]}]
    end

    test "decodes a hex escape with a trailing space in an id" do
      assert DOM.CSS.parse(~S(#a\3A b)) == [{:compound, [{:id, "a:b"}]}]
    end

    test "decodes a hex escape without a trailing space" do
      assert DOM.CSS.parse(~S(.\41)) == [{:compound, [{:class, "A"}]}]
    end

    test "decodes an escaped leading digit" do
      assert DOM.CSS.parse(~S(.\31 23)) == [{:compound, [{:class, "123"}]}]
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

  describe "pseudo-classes" do
    test "keyword pseudo-class" do
      assert DOM.CSS.parse(":first-child") == [{:compound, [{:pseudo_class, "first-child"}]}]
    end

    test "pseudo-class on a compound" do
      assert DOM.CSS.parse("a:hover") ==
               [{:compound, [{:type, "a"}, {:pseudo_class, "hover"}]}]
    end
  end

  describe ":nth-child(An+B)" do
    test "odd keyword" do
      assert DOM.CSS.parse(":nth-child(odd)") ==
               [{:compound, [{:pseudo_class, "nth-child", {2, 1}}]}]
    end

    test "even keyword" do
      assert DOM.CSS.parse(":nth-child(even)") ==
               [{:compound, [{:pseudo_class, "nth-child", {2, 0}}]}]
    end

    test "bare integer" do
      assert DOM.CSS.parse(":nth-child(3)") ==
               [{:compound, [{:pseudo_class, "nth-child", {0, 3}}]}]
    end

    test "An+B form" do
      assert DOM.CSS.parse(":nth-child(2n+1)") ==
               [{:compound, [{:pseudo_class, "nth-child", {2, 1}}]}]
    end

    test "negative and spaced An+B" do
      assert DOM.CSS.parse(":nth-child(3n - 2)") ==
               [{:compound, [{:pseudo_class, "nth-child", {3, -2}}]}]
    end

    test "-n form" do
      assert DOM.CSS.parse(":nth-child(-n)") ==
               [{:compound, [{:pseudo_class, "nth-child", {-1, 0}}]}]
    end

    test "n form" do
      assert DOM.CSS.parse(":nth-child(n)") ==
               [{:compound, [{:pseudo_class, "nth-child", {1, 0}}]}]
    end
  end

  describe ":not()" do
    test "negation with a simple selector" do
      assert DOM.CSS.parse(":not(.box)") ==
               [{:compound, [{:not, [{:compound, [{:class, "box"}]}]}]}]
    end

    test "negation with a selector list" do
      assert DOM.CSS.parse(":not(.a, #b)") ==
               [
                 {:compound, [{:not, [{:compound, [{:class, "a"}]}, {:compound, [{:id, "b"}]}]}]}
               ]
    end
  end

  describe "functional pseudo-classes" do
    test ":is with a selector list" do
      assert DOM.CSS.parse(":is(.a, #b)") ==
               [
                 {:compound,
                  [
                    {:pseudo_class, "is",
                     {:selector_list, [{:compound, [{:class, "a"}]}, {:compound, [{:id, "b"}]}]}}
                  ]}
               ]
    end

    test ":where with a compound" do
      assert DOM.CSS.parse(":where(a.x)") ==
               [
                 {:compound,
                  [
                    {:pseudo_class, "where",
                     {:selector_list, [{:compound, [{:type, "a"}, {:class, "x"}]}]}}
                  ]}
               ]
    end

    test ":lang with a single ident argument" do
      assert DOM.CSS.parse(":lang(en)") ==
               [{:compound, [{:pseudo_class, "lang", {:args, ["en"]}}]}]
    end

    test ":lang with multiple arguments" do
      assert DOM.CSS.parse(":lang(en, fr)") ==
               [{:compound, [{:pseudo_class, "lang", {:args, ["en", "fr"]}}]}]
    end

    test ":dir argument" do
      assert DOM.CSS.parse(":dir(ltr)") ==
               [{:compound, [{:pseudo_class, "dir", {:args, ["ltr"]}}]}]
    end

    test ":has with a child-combinator relative selector" do
      assert DOM.CSS.parse(":has(> .child)") ==
               [
                 {:compound,
                  [
                    {:pseudo_class, "has",
                     {:selector_list, [[:child, {:compound, [{:class, "child"}]}]]}}
                  ]}
               ]
    end

    test ":has with a next-sibling relative selector" do
      assert DOM.CSS.parse(":has(+ p)") ==
               [
                 {:compound,
                  [
                    {:pseudo_class, "has",
                     {:selector_list, [[:next_sibling, {:compound, [{:type, "p"}]}]]}}
                  ]}
               ]
    end

    test ":has with a plain descendant relative selector" do
      assert DOM.CSS.parse(":has(.child)") ==
               [
                 {:compound,
                  [{:pseudo_class, "has", {:selector_list, [{:compound, [{:class, "child"}]}]}}]}
               ]
    end
  end

  describe "pseudo-elements" do
    test "double-colon pseudo-element" do
      assert DOM.CSS.parse("::before") == [{:compound, [{:pseudo_element, "before"}]}]
    end

    test "pseudo-element on a compound" do
      assert DOM.CSS.parse("p::first-line") ==
               [{:compound, [{:type, "p"}, {:pseudo_element, "first-line"}]}]
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
