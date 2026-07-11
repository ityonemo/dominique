defmodule Integration.ParentChildMixinTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#interface-parentnode"

    # ParentNode/ChildNode mutators produce the same tree as the browser: before/
    # after/replace_with/prepend/append with a mix of elements and strings.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='p'><b id='x'>x</b></div>", "text/html");
      const p = doc.getElementById("p"), x = doc.getElementById("x");
      const el = (id) => { const e = doc.createElement("i"); e.id = id; return e; };

      x.before(el("b1"), "t1");
      x.after(el("a1"));
      p.prepend(el("pre"));
      p.append(el("app"), "tail");

      // element-only reads
      const childIds = Array.from(p.children, c => c.id);
      const count = p.childElementCount;
      const firstId = p.firstElementChild.id;
      const lastId = p.lastElementChild.id;
      const xPrev = x.previousElementSibling && x.previousElementSibling.id;
      const xNext = x.nextElementSibling && x.nextElementSibling.id;

      // replace_with then remove
      doc.getElementById("a1").replaceWith(el("rep"));
      doc.getElementById("pre").remove();

      return {
        html: p.innerHTML,
        childIds, count, firstId, lastId, xPrev, xNext
      };
    });
    """

    test "parent/child mixin mutations match the browser", %{js: expected} do
      doc = DOM.new("<div id='p'><b id='x'>x</b></div>")
      p = DOM.query_selector(doc, "#p")
      x = DOM.query_selector(doc, "#x")

      el = fn id ->
        e = DOM.create_element(doc, "i")
        Element.set_attribute(e, "id", id)
        e
      end

      Node.before(x, [el.("b1"), "t1"])
      Node.after(x, [el.("a1")])
      Node.prepend(p, [el.("pre")])
      Node.append(p, [el.("app"), "tail"])

      child_ids = Enum.map(Node.children(p), &Element.get_attribute(&1, "id"))
      count = Node.child_element_count(p)
      first_id = Element.get_attribute(Node.first_element_child(p), "id")
      last_id = Element.get_attribute(Node.last_element_child(p), "id")

      id_of = fn
        nil -> nil
        s -> Element.get_attribute(s, "id")
      end

      x_prev = id_of.(Node.previous_element_sibling(x))
      x_next = id_of.(Node.next_element_sibling(x))

      Node.replace_with(DOM.query_selector(doc, "#a1"), [el.("rep")])
      Node.remove(DOM.query_selector(doc, "#pre"))

      result = %{
        "html" => Element.inner_html(p),
        "childIds" => child_ids,
        "count" => count,
        "firstId" => first_id,
        "lastId" => last_id,
        "xPrev" => x_prev,
        "xNext" => x_next
      }

      assert result == expected
    end
  end
end
