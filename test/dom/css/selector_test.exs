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

  describe "compound selectors" do
    test "type with id and class" do
      assert DOM.CSS.parse("a#main.box") ==
               [{:compound, [{:type, "a"}, {:id, "main"}, {:class, "box"}]}]
    end

    test "universal with class" do
      assert DOM.CSS.parse("*.box") == [{:compound, [:universal, {:class, "box"}]}]
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
