defmodule DOM.Element.TokenListTest do
  use DOM.Case, async: true

  # T5: classList (DOMTokenList). Reads parse the class attribute's tokens (deduped,
  # whitespace-split) WITHOUT rewriting it; mutations reserialize to a space-joined
  # deduped token list. Functions take the element handle (no live sub-object).

  alias DOM.Element
  alias DOM.TokenList

  defp el(class) do
    doc = new_document("<div id='d' class='#{class}'></div>")
    DOM.query_selector(doc, "#d")
  end

  describe "reads (no rewrite)" do
    test "length / item / contains parse deduped tokens" do
      d = el("  a b  a c ")
      assert TokenList.length(d) == 3
      assert TokenList.item(d, 0) == "a"
      assert TokenList.item(d, 2) == "c"
      assert TokenList.item(d, 9) == nil
      assert TokenList.contains(d, "b")
      refute TokenList.contains(d, "z")
    end

    test "reads do not rewrite the class attribute" do
      d = el("  a b  a c ")
      TokenList.contains(d, "a")
      assert Element.get_attribute(d, "class") == "  a b  a c "
    end
  end

  describe "mutations (reserialize)" do
    test "add appends new tokens, dedups, drops extra whitespace" do
      d = el("  a b  a c ")
      TokenList.add(d, ["d", "a"])
      assert Element.get_attribute(d, "class") == "a b c d"
    end

    test "remove drops tokens" do
      d = el("a b c")
      TokenList.remove(d, ["b"])
      assert Element.get_attribute(d, "class") == "a c"
    end

    test "toggle returns final presence" do
      d = el("a c")
      assert TokenList.toggle(d, "c") == false
      assert Element.get_attribute(d, "class") == "a"
      assert TokenList.toggle(d, "x") == true
      assert Element.get_attribute(d, "class") == "a x"
    end

    test "toggle force adds/removes unconditionally" do
      d = el("a")
      assert TokenList.toggle(d, "a", true) == true
      assert Element.get_attribute(d, "class") == "a"
      assert TokenList.toggle(d, "a", false) == false
      assert Element.get_attribute(d, "class") == ""
    end

    test "replace swaps a token, returning whether it replaced" do
      d = el("a b")
      assert TokenList.replace(d, "a", "A") == true
      assert Element.get_attribute(d, "class") == "A b"
      assert TokenList.replace(d, "nope", "X") == false
      assert Element.get_attribute(d, "class") == "A b"
    end
  end
end
