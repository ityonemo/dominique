defmodule Integration.FocusTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/interaction.html#dom-focus"

    # focus() sets activeElement and :focus; non-focusable focus() is a no-op;
    # :focus-within matches up the ancestor chain; blur returns to body. We build the
    # same tree + focus sequence in Elixir and compare.
    @js """
    return await page.evaluate(() => {
      const host = document.createElement("div");
      host.innerHTML =
        "<div id='outer'><div id='mid'><input id='inner'></div></div>" +
        "<span id='sp'></span><button id='btn'>b</button>";
      document.body.appendChild(host);
      const $ = (s) => host.querySelector(s);
      const out = {};

      $("#inner").focus();
      out.active_after_focus = document.activeElement.id;
      out.inner_focus = $("#inner").matches(":focus");
      out.outer_within = $("#outer").matches(":focus-within");
      out.mid_within = $("#mid").matches(":focus-within");
      out.sp_within = $("#sp").matches(":focus-within");

      $("#sp").focus();   // span not focusable — no-op
      out.after_span_focus = document.activeElement.id;

      $("#btn").focus();
      out.after_button_focus = document.activeElement.id;
      $("#btn").blur();
      out.after_blur = document.activeElement.nodeName.toLowerCase();

      document.body.removeChild(host);
      return out;
    });
    """

    test "focus / :focus / :focus-within / blur match the browser", %{js: expected} do
      doc =
        DOM.new(
          "<body><div id='outer'><div id='mid'><input id='inner'></div></div>" <>
            "<span id='sp'></span><button id='btn'>b</button></body>"
        )

      q = fn s -> DOM.query_selector(doc, s) end

      Node.focus(q.("#inner"))

      out = %{
        "active_after_focus" => DOM.Element.get_attribute(DOM.active_element(doc), "id"),
        "inner_focus" => DOM.matches(q.("#inner"), ":focus"),
        "outer_within" => DOM.matches(q.("#outer"), ":focus-within"),
        "mid_within" => DOM.matches(q.("#mid"), ":focus-within"),
        "sp_within" => DOM.matches(q.("#sp"), ":focus-within")
      }

      Node.focus(q.("#sp"))

      out =
        Map.put(out, "after_span_focus", DOM.Element.get_attribute(DOM.active_element(doc), "id"))

      Node.focus(q.("#btn"))

      out =
        Map.put(
          out,
          "after_button_focus",
          DOM.Element.get_attribute(DOM.active_element(doc), "id")
        )

      Node.blur(q.("#btn"))
      out = Map.put(out, "after_blur", Node.node_name(DOM.active_element(doc)))

      assert out == expected
    end
  end
end
