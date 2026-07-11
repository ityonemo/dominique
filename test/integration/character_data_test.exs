defmodule Integration.CharacterDataTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.CharacterData, as: CD
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#interface-characterdata"

    # CharacterData string edits + wholeText match the browser.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString("<p id='p'>hello</p>", "text/html");
      const t = doc.getElementById("p").firstChild;
      const r = {};
      r.length = t.length;
      r.substring = t.substringData(1, 3);
      t.appendData(" world");  r.after_append = t.data;
      t.insertData(0, ">> ");  r.after_insert = t.data;
      t.deleteData(0, 3);      r.after_delete = t.data;
      t.replaceData(0, 5, "HELLO"); r.after_replace = t.data;

      const p2 = doc.createElement("p");
      const a = doc.createTextNode("foo"), bar = doc.createTextNode("bar");
      p2.append(a, bar, doc.createElement("b"), doc.createTextNode("baz"));
      r.whole = a.wholeText;

      try { t.substringData(100, 1); r.oob = "no throw"; }
      catch (e) { r.oob = e.name; }
      return r;
    });
    """

    test "CharacterData edits + wholeText match the browser", %{js: expected} do
      doc = DOM.new("<p id='p'>hello</p>")
      p = DOM.query_selector(doc, "#p")
      [t] = Node.child_nodes(p)

      length = CD.length(t)
      substring = CD.substring_data(t, 1, 3)
      CD.append_data(t, " world")
      after_append = Node.value(t)
      CD.insert_data(t, 0, ">> ")
      after_insert = Node.value(t)
      CD.delete_data(t, 0, 3)
      after_delete = Node.value(t)
      CD.replace_data(t, 0, 5, "HELLO")
      after_replace = Node.value(t)

      p2 = DOM.create_element(doc, "p")
      Node.append(p2, ["foo", "bar"])
      b = DOM.create_element(doc, "b")
      Node.append(p2, [b, "baz"])
      [a | _] = Node.child_nodes(p2)
      whole = DOM.Text.whole_text(a)

      oob =
        try do
          CD.substring_data(t, 100, 1)
          "no throw"
        rescue
          DOM.IndexSizeError -> "IndexSizeError"
        end

      result = %{
        "length" => length,
        "substring" => substring,
        "after_append" => after_append,
        "after_insert" => after_insert,
        "after_delete" => after_delete,
        "after_replace" => after_replace,
        "whole" => whole,
        "oob" => oob
      }

      assert result == expected
    end
  end
end
