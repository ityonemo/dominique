defmodule Integration.TokenListTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.TokenList

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#interface-domtokenlist"

    # classList reads (deduped tokens, no rewrite) and the mutation sequence
    # (reserialize to space-joined) match the browser.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='d' class='  a b  a c '></div>", "text/html");
      const d = doc.getElementById("d");
      const r = {};
      r.length = d.classList.length;
      r.item0 = d.classList.item(0);
      r.contains_a = d.classList.contains("a");
      r.raw_after_reads = d.className;

      d.classList.add("d", "a");        r.after_add = d.className;
      d.classList.remove("b");          r.after_remove = d.className;
      r.toggle_ret = d.classList.toggle("c"); r.after_toggle = d.className;
      r.toggle_force = d.classList.toggle("z", true); r.after_force = d.className;
      r.replace_ret = d.classList.replace("a", "A"); r.after_replace = d.className;
      return r;
    });
    """

    test "classList reads + mutation sequence match the browser", %{js: expected} do
      doc = DOM.new("<div id='d' class='  a b  a c '></div>")
      d = DOM.query_selector(doc, "#d")

      length = TokenList.length(d)
      item0 = TokenList.item(d, 0)
      contains_a = TokenList.contains(d, "a")
      raw_after_reads = Element.get_attribute(d, "class")

      TokenList.add(d, ["d", "a"])
      after_add = Element.get_attribute(d, "class")
      TokenList.remove(d, ["b"])
      after_remove = Element.get_attribute(d, "class")
      toggle_ret = TokenList.toggle(d, "c")
      after_toggle = Element.get_attribute(d, "class")
      toggle_force = TokenList.toggle(d, "z", true)
      after_force = Element.get_attribute(d, "class")
      replace_ret = TokenList.replace(d, "a", "A")
      after_replace = Element.get_attribute(d, "class")

      result = %{
        "length" => length,
        "item0" => item0,
        "contains_a" => contains_a,
        "raw_after_reads" => raw_after_reads,
        "after_add" => after_add,
        "after_remove" => after_remove,
        "toggle_ret" => toggle_ret,
        "after_toggle" => after_toggle,
        "toggle_force" => toggle_force,
        "after_force" => after_force,
        "replace_ret" => replace_ret,
        "after_replace" => after_replace
      }

      assert result == expected
    end
  end
end
