defmodule DOM.CSS.SelectorTest do
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

  describe "simple selectors" do
    test "type selector" do
      assert DOM.CSS.parse("div") == [%Compound{simples: [%Type{name: "div"}]}]
    end

    test "universal selector" do
      assert DOM.CSS.parse("*") == [%Compound{simples: [%Universal{}]}]
    end

    test "id selector" do
      assert DOM.CSS.parse("#main") == [%Compound{simples: [%Id{name: "main"}]}]
    end

    test "class selector" do
      assert DOM.CSS.parse(".box") == [%Compound{simples: [%Class{name: "box"}]}]
    end
  end

  describe "names" do
    test "accepts hyphens, underscores, and digits after the first character" do
      assert DOM.CSS.parse("data-item_2") == [%Compound{simples: [%Type{name: "data-item_2"}]}]
      assert DOM.CSS.parse(".is-active_1") == [%Compound{simples: [%Class{name: "is-active_1"}]}]
    end

    test "decodes a character escape in a class name" do
      assert DOM.CSS.parse(~S(.foo\.bar)) == [%Compound{simples: [%Class{name: "foo.bar"}]}]
    end

    test "decodes a hex escape with a trailing space in an id" do
      assert DOM.CSS.parse(~S(#a\3A b)) == [%Compound{simples: [%Id{name: "a:b"}]}]
    end

    test "decodes a hex escape without a trailing space" do
      assert DOM.CSS.parse(~S(.\41)) == [%Compound{simples: [%Class{name: "A"}]}]
    end

    test "decodes an escaped leading digit" do
      assert DOM.CSS.parse(~S(.\31 23)) == [%Compound{simples: [%Class{name: "123"}]}]
    end

    test "accepts non-ASCII characters unescaped" do
      assert DOM.CSS.parse(".café") == [%Compound{simples: [%Class{name: "café"}]}]
      assert DOM.CSS.parse("#日本語") == [%Compound{simples: [%Id{name: "日本語"}]}]
      assert DOM.CSS.parse("naïve") == [%Compound{simples: [%Type{name: "naïve"}]}]
    end

    test "does not escape non-ASCII characters when serializing" do
      assert DOM.CSS.to_string(DOM.CSS.parse(".café")) == ".café"
    end
  end

  describe "attribute selectors" do
    test "presence" do
      assert DOM.CSS.parse("[disabled]") == [%Compound{simples: [%Attribute{name: "disabled"}]}]
    end

    test "equals with unquoted value" do
      assert DOM.CSS.parse("[type=text]") ==
               [%Compound{simples: [%Attribute{name: "type", op: :eq, value: "text"}]}]
    end

    test "equals with double-quoted value" do
      assert DOM.CSS.parse(~s([type="text"])) ==
               [%Compound{simples: [%Attribute{name: "type", op: :eq, value: "text"}]}]
    end

    test "equals with single-quoted value" do
      assert DOM.CSS.parse("[type='text']") ==
               [%Compound{simples: [%Attribute{name: "type", op: :eq, value: "text"}]}]
    end

    test "includes operator ~=" do
      assert DOM.CSS.parse("[class~=box]") ==
               [%Compound{simples: [%Attribute{name: "class", op: :includes, value: "box"}]}]
    end

    test "dash operator |=" do
      assert DOM.CSS.parse("[lang|=en]") ==
               [%Compound{simples: [%Attribute{name: "lang", op: :dash, value: "en"}]}]
    end

    test "prefix operator ^=" do
      assert DOM.CSS.parse("[href^=http]") ==
               [%Compound{simples: [%Attribute{name: "href", op: :prefix, value: "http"}]}]
    end

    test "suffix operator $= with a quoted value" do
      assert DOM.CSS.parse(~s([src$=".png"])) ==
               [%Compound{simples: [%Attribute{name: "src", op: :suffix, value: ".png"}]}]
    end

    test "substring operator *=" do
      assert DOM.CSS.parse("[title*=hello]") ==
               [%Compound{simples: [%Attribute{name: "title", op: :substring, value: "hello"}]}]
    end

    test "case-insensitive flag" do
      assert DOM.CSS.parse("[type=text i]") ==
               [%Compound{simples: [%Attribute{name: "type", op: :eq, value: "text", flag: :i}]}]
    end

    test "case-sensitive flag" do
      assert DOM.CSS.parse("[type=text s]") ==
               [%Compound{simples: [%Attribute{name: "type", op: :eq, value: "text", flag: :s}]}]
    end

    test "combines with other simple selectors in a compound" do
      assert DOM.CSS.parse("a[href^=http].external") ==
               [
                 %Compound{
                   simples: [
                     %Type{name: "a"},
                     %Attribute{name: "href", op: :prefix, value: "http"},
                     %Class{name: "external"}
                   ]
                 }
               ]
    end
  end

  describe "namespaces" do
    test "named namespace on a type" do
      assert DOM.CSS.parse("svg|rect") ==
               [%Compound{simples: [%Type{name: "rect", namespace: "svg"}]}]
    end

    test "any namespace on a type" do
      assert DOM.CSS.parse("*|div") ==
               [%Compound{simples: [%Type{name: "div", namespace: :any}]}]
    end

    test "empty namespace on a type" do
      assert DOM.CSS.parse("|div") ==
               [%Compound{simples: [%Type{name: "div", namespace: :none}]}]
    end

    test "namespace on the universal selector" do
      assert DOM.CSS.parse("svg|*") == [%Compound{simples: [%Universal{namespace: "svg"}]}]
    end

    test "any-namespace universal" do
      assert DOM.CSS.parse("*|*") == [%Compound{simples: [%Universal{namespace: :any}]}]
    end

    test "namespace on an attribute" do
      assert DOM.CSS.parse("[svg|href]") ==
               [%Compound{simples: [%Attribute{name: "href", namespace: "svg"}]}]
    end
  end

  describe "compound selectors" do
    test "type with id and class" do
      assert DOM.CSS.parse("a#main.box") ==
               [%Compound{simples: [%Type{name: "a"}, %Id{name: "main"}, %Class{name: "box"}]}]
    end

    test "universal with class" do
      assert DOM.CSS.parse("*.box") == [%Compound{simples: [%Universal{}, %Class{name: "box"}]}]
    end
  end

  describe "pseudo-classes" do
    test "keyword pseudo-class" do
      assert DOM.CSS.parse(":first-child") ==
               [%Compound{simples: [%PseudoClass{name: "first-child"}]}]
    end

    test "pseudo-class on a compound" do
      assert DOM.CSS.parse("a:hover") ==
               [%Compound{simples: [%Type{name: "a"}, %PseudoClass{name: "hover"}]}]
    end
  end

  describe ":nth-child(An+B)" do
    test "odd keyword" do
      assert DOM.CSS.parse(":nth-child(odd)") ==
               [%Compound{simples: [%PseudoClass{name: "nth-child", arg: {2, 1}}]}]
    end

    test "even keyword" do
      assert DOM.CSS.parse(":nth-child(even)") ==
               [%Compound{simples: [%PseudoClass{name: "nth-child", arg: {2, 0}}]}]
    end

    test "bare integer" do
      assert DOM.CSS.parse(":nth-child(3)") ==
               [%Compound{simples: [%PseudoClass{name: "nth-child", arg: {0, 3}}]}]
    end

    test "An+B form" do
      assert DOM.CSS.parse(":nth-child(2n+1)") ==
               [%Compound{simples: [%PseudoClass{name: "nth-child", arg: {2, 1}}]}]
    end

    test "negative and spaced An+B" do
      assert DOM.CSS.parse(":nth-child(3n - 2)") ==
               [%Compound{simples: [%PseudoClass{name: "nth-child", arg: {3, -2}}]}]
    end

    test "-n form" do
      assert DOM.CSS.parse(":nth-child(-n)") ==
               [%Compound{simples: [%PseudoClass{name: "nth-child", arg: {-1, 0}}]}]
    end

    test "n form" do
      assert DOM.CSS.parse(":nth-child(n)") ==
               [%Compound{simples: [%PseudoClass{name: "nth-child", arg: {1, 0}}]}]
    end

    test "An+B of S form" do
      assert DOM.CSS.parse(":nth-child(2n+1 of .item)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "nth-child",
                       arg: {2, 1, [%Compound{simples: [%Class{name: "item"}]}]}
                     }
                   ]
                 }
               ]
    end

    test "of S with a selector list" do
      assert DOM.CSS.parse(":nth-child(odd of .a, #b)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "nth-child",
                       arg:
                         {2, 1,
                          [
                            %Compound{simples: [%Class{name: "a"}]},
                            %Compound{simples: [%Id{name: "b"}]}
                          ]}
                     }
                   ]
                 }
               ]
    end
  end

  describe ":not()" do
    test "negation with a simple selector" do
      assert DOM.CSS.parse(":not(.box)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "not",
                       arg: {:selector_list, [%Compound{simples: [%Class{name: "box"}]}]}
                     }
                   ]
                 }
               ]
    end

    test "negation with a selector list" do
      assert DOM.CSS.parse(":not(.a, #b)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "not",
                       arg:
                         {:selector_list,
                          [
                            %Compound{simples: [%Class{name: "a"}]},
                            %Compound{simples: [%Id{name: "b"}]}
                          ]}
                     }
                   ]
                 }
               ]
    end
  end

  describe "functional pseudo-classes" do
    test ":is with a selector list" do
      assert DOM.CSS.parse(":is(.a, #b)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "is",
                       arg:
                         {:selector_list,
                          [
                            %Compound{simples: [%Class{name: "a"}]},
                            %Compound{simples: [%Id{name: "b"}]}
                          ]}
                     }
                   ]
                 }
               ]
    end

    test ":where with a compound" do
      assert DOM.CSS.parse(":where(a.x)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "where",
                       arg:
                         {:selector_list,
                          [%Compound{simples: [%Type{name: "a"}, %Class{name: "x"}]}]}
                     }
                   ]
                 }
               ]
    end

    test ":lang with a single ident argument" do
      assert DOM.CSS.parse(":lang(en)") ==
               [%Compound{simples: [%PseudoClass{name: "lang", arg: {:args, ["en"]}}]}]
    end

    test ":lang with multiple arguments" do
      assert DOM.CSS.parse(":lang(en, fr)") ==
               [%Compound{simples: [%PseudoClass{name: "lang", arg: {:args, ["en", "fr"]}}]}]
    end

    test ":dir argument" do
      assert DOM.CSS.parse(":dir(ltr)") ==
               [%Compound{simples: [%PseudoClass{name: "dir", arg: {:args, ["ltr"]}}]}]
    end

    test ":has with a child-combinator relative selector" do
      assert DOM.CSS.parse(":has(> .child)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "has",
                       arg:
                         {:selector_list,
                          [
                            %Complex{
                              parts: [:child, %Compound{simples: [%Class{name: "child"}]}]
                            }
                          ]}
                     }
                   ]
                 }
               ]
    end

    test ":has with a next-sibling relative selector" do
      assert DOM.CSS.parse(":has(+ p)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "has",
                       arg:
                         {:selector_list,
                          [
                            %Complex{
                              parts: [:next_sibling, %Compound{simples: [%Type{name: "p"}]}]
                            }
                          ]}
                     }
                   ]
                 }
               ]
    end

    test ":has with a plain descendant relative selector" do
      assert DOM.CSS.parse(":has(.child)") ==
               [
                 %Compound{
                   simples: [
                     %PseudoClass{
                       name: "has",
                       arg: {:selector_list, [%Compound{simples: [%Class{name: "child"}]}]}
                     }
                   ]
                 }
               ]
    end
  end

  describe "pseudo-elements" do
    test "double-colon pseudo-element" do
      assert DOM.CSS.parse("::before") ==
               [%Compound{simples: [%PseudoElement{name: "before"}]}]
    end

    test "pseudo-element on a compound" do
      assert DOM.CSS.parse("p::first-line") ==
               [%Compound{simples: [%Type{name: "p"}, %PseudoElement{name: "first-line"}]}]
    end
  end

  describe "combinators" do
    test "descendant combinator (whitespace)" do
      assert DOM.CSS.parse("div .box") ==
               [
                 %Complex{
                   parts: [
                     %Compound{simples: [%Type{name: "div"}]},
                     :descendant,
                     %Compound{simples: [%Class{name: "box"}]}
                   ]
                 }
               ]
    end

    test "child combinator" do
      assert DOM.CSS.parse("ul > li") ==
               [
                 %Complex{
                   parts: [
                     %Compound{simples: [%Type{name: "ul"}]},
                     :child,
                     %Compound{simples: [%Type{name: "li"}]}
                   ]
                 }
               ]
    end

    test "next-sibling combinator" do
      assert DOM.CSS.parse("h1 + p") ==
               [
                 %Complex{
                   parts: [
                     %Compound{simples: [%Type{name: "h1"}]},
                     :next_sibling,
                     %Compound{simples: [%Type{name: "p"}]}
                   ]
                 }
               ]
    end

    test "subsequent-sibling combinator" do
      assert DOM.CSS.parse("h1 ~ p") ==
               [
                 %Complex{
                   parts: [
                     %Compound{simples: [%Type{name: "h1"}]},
                     :subsequent_sibling,
                     %Compound{simples: [%Type{name: "p"}]}
                   ]
                 }
               ]
    end

    test "child combinator without surrounding whitespace" do
      assert DOM.CSS.parse("ul>li") ==
               [
                 %Complex{
                   parts: [
                     %Compound{simples: [%Type{name: "ul"}]},
                     :child,
                     %Compound{simples: [%Type{name: "li"}]}
                   ]
                 }
               ]
    end

    test "chained combinators" do
      assert DOM.CSS.parse("section > ul li") ==
               [
                 %Complex{
                   parts: [
                     %Compound{simples: [%Type{name: "section"}]},
                     :child,
                     %Compound{simples: [%Type{name: "ul"}]},
                     :descendant,
                     %Compound{simples: [%Type{name: "li"}]}
                   ]
                 }
               ]
    end
  end

  describe "selector lists" do
    test "comma-separated compounds" do
      assert DOM.CSS.parse(".a, .b") ==
               [%Compound{simples: [%Class{name: "a"}]}, %Compound{simples: [%Class{name: "b"}]}]
    end

    test "comma-separated complex selectors" do
      assert DOM.CSS.parse("div > a, .box") ==
               [
                 %Complex{
                   parts: [
                     %Compound{simples: [%Type{name: "div"}]},
                     :child,
                     %Compound{simples: [%Type{name: "a"}]}
                   ]
                 },
                 %Compound{simples: [%Class{name: "box"}]}
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
