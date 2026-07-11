defmodule Integration.ElementConvenienceTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#dom-element-insertadjacenthtml"

    # closest, toggleAttribute, and insertAdjacentHTML (all four positions) produce
    # the same result as the browser.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='a' class='box'><section id='b'><span id='c'>x</span></section></div>",
        "text/html");
      const c = doc.getElementById("c");

      const closest_section = c.closest("section").id;
      const closest_box = c.closest(".box").id;
      const closest_none = c.closest("table");

      const d = doc.createElement("div");
      const t1 = d.toggleAttribute("hidden");   // true
      const has1 = d.hasAttribute("hidden");
      const t2 = d.toggleAttribute("hidden");   // false
      const t3 = d.toggleAttribute("x", true);
      const t4 = d.toggleAttribute("x", false);

      const iah = new DOMParser().parseFromString(
        "<div id='p'><b id='t'>T</b></div>", "text/html");
      const target = iah.getElementById("t");
      target.insertAdjacentHTML("beforebegin", "<i>B</i>");
      target.insertAdjacentHTML("afterend", "<i>A</i>");
      target.insertAdjacentHTML("afterbegin", "<u>u</u>");
      target.insertAdjacentHTML("beforeend", "<u>v</u>");
      const iah_html = iah.getElementById("p").outerHTML;

      return {
        closest_section, closest_box, closest_none,
        t1, has1, t2, t3, t4,
        iah_html
      };
    });
    """

    test "closest / toggleAttribute / insertAdjacentHTML match the browser", %{js: expected} do
      doc =
        DOM.new("<div id='a' class='box'><section id='b'><span id='c'>x</span></section></div>")

      c = DOM.query_selector(doc, "#c")
      d = DOM.create_element(doc, "div")

      iah = DOM.new("<div id='p'><b id='t'>T</b></div>")
      target = DOM.query_selector(iah, "#t")
      Element.insert_adjacent_html(target, "beforebegin", "<i>B</i>")
      Element.insert_adjacent_html(target, "afterend", "<i>A</i>")
      Element.insert_adjacent_html(target, "afterbegin", "<u>u</u>")
      Element.insert_adjacent_html(target, "beforeend", "<u>v</u>")

      result = %{
        "closest_section" => Element.get_attribute(Element.closest(c, "section"), "id"),
        "closest_box" => Element.get_attribute(Element.closest(c, ".box"), "id"),
        "closest_none" => Element.closest(c, "table"),
        "t1" => Element.toggle_attribute(d, "hidden"),
        "has1" => Element.has_attribute(d, "hidden"),
        "t2" => Element.toggle_attribute(d, "hidden"),
        "t3" => Element.toggle_attribute(d, "x", true),
        "t4" => Element.toggle_attribute(d, "x", false),
        "iah_html" => Element.outer_html(DOM.query_selector(iah, "#p"))
      }

      assert result == expected
    end
  end
end
