defmodule Integration.DefaultActionTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Event
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/input.html#checkbox-state-(type=checkbox)"

    # Dispatching a click runs the default action (toggle checkedness) unless
    # preventDefault; checkedness is a property, not the attribute; radio clears its
    # group. We run the same dispatches in Elixir and compare the observable state.
    @js """
    return await page.evaluate(() => {
      const host = document.createElement("div");
      host.innerHTML =
        "<input type='checkbox' id='c'>" +
        "<input type='checkbox' id='cp'>" +
        "<input type='radio' name='g' id='r1'><input type='radio' name='g' id='r2'>";
      document.body.appendChild(host);
      const $ = (s) => host.querySelector(s);
      const click = (el, opts) => el.dispatchEvent(new MouseEvent("click", Object.assign({cancelable:true}, opts)));

      // plain checkbox toggle
      click($("#c"));
      const c_checked = $("#c").matches(":checked");
      const c_attr = $("#c").hasAttribute("checked");

      // preventDefault
      $("#cp").addEventListener("click", e => e.preventDefault());
      const cp_ret = click($("#cp"));
      const cp_checked = $("#cp").matches(":checked");

      // radio group
      click($("#r1"));
      click($("#r2"));
      const r1 = $("#r1").matches(":checked"), r2 = $("#r2").matches(":checked");

      document.body.removeChild(host);
      return { c_checked, c_attr, cp_ret, cp_checked, r1, r2 };
    });
    """

    test "click default actions match the browser", %{js: expected} do
      doc =
        DOM.new(
          "<body><input type='checkbox' id='c'><input type='checkbox' id='cp'>" <>
            "<input type='radio' name='g' id='r1'><input type='radio' name='g' id='r2'></body>"
        )

      q = fn s -> DOM.query_selector(doc, s) end
      click = fn el -> Node.dispatch_event(el, Event.new("click", cancelable: true)) end

      click.(q.("#c"))

      Node.add_event_listener(q.("#cp"), "click", fn %Event{} = e -> Event.prevent_default(e) end)
      cp_ret = click.(q.("#cp"))

      click.(q.("#r1"))
      click.(q.("#r2"))

      out = %{
        "c_checked" => DOM.matches(q.("#c"), ":checked"),
        "c_attr" => DOM.Element.has_attribute(q.("#c"), "checked"),
        "cp_ret" => cp_ret,
        "cp_checked" => DOM.matches(q.("#cp"), ":checked"),
        "r1" => DOM.matches(q.("#r1"), ":checked"),
        "r2" => DOM.matches(q.("#r2"), ":checked")
      }

      assert out == expected
    end
  end
end
