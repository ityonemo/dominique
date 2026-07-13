defmodule Integration.IndeterminateTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Event
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/semantics-other.html#selector-indeterminate"

    # :indeterminate — checkbox property (set via IDL, cleared by click); radio group
    # with none checked; progress without value. We reproduce the observable matches.
    @js """
    return await page.evaluate(() => {
      const host = document.createElement("div");
      host.innerHTML =
        "<input type='checkbox' id='c'>" +
        "<input type='radio' name='g' id='r1'><input type='radio' name='g' id='r2'>" +
        "<progress id='p'></progress><progress id='p2' value='0.5'></progress>";
      document.body.appendChild(host);
      const $ = (s) => host.querySelector(s);

      const out = {};
      out.cb_default = $("#c").matches(":indeterminate");
      $("#c").indeterminate = true;
      out.cb_set = $("#c").matches(":indeterminate");
      $("#c").dispatchEvent(new MouseEvent("click", {bubbles:true, cancelable:true}));
      out.cb_after_click = $("#c").matches(":indeterminate");

      out.radio_none = $("#r1").matches(":indeterminate");
      $("#r1").dispatchEvent(new MouseEvent("click", {bubbles:true, cancelable:true}));
      out.radio_after = $("#r1").matches(":indeterminate");

      out.progress_novalue = $("#p").matches(":indeterminate");
      out.progress_value = $("#p2").matches(":indeterminate");

      document.body.removeChild(host);
      return out;
    });
    """

    test ":indeterminate matches the browser", %{js: expected} do
      doc =
        DOM.new(
          "<body><input type='checkbox' id='c'>" <>
            "<input type='radio' name='g' id='r1'><input type='radio' name='g' id='r2'>" <>
            "<progress id='p'></progress><progress id='p2' value='0.5'></progress></body>"
        )

      q = fn s -> DOM.query_selector(doc, s) end

      click = fn el ->
        Node.dispatch_event(el, Event.new("click", bubbles: true, cancelable: true))
      end

      out = %{"cb_default" => DOM.matches(q.("#c"), ":indeterminate")}
      DOM.set_indeterminate(q.("#c"), true)
      out = Map.put(out, "cb_set", DOM.matches(q.("#c"), ":indeterminate"))
      click.(q.("#c"))
      out = Map.put(out, "cb_after_click", DOM.matches(q.("#c"), ":indeterminate"))

      out = Map.put(out, "radio_none", DOM.matches(q.("#r1"), ":indeterminate"))
      click.(q.("#r1"))
      out = Map.put(out, "radio_after", DOM.matches(q.("#r1"), ":indeterminate"))

      out = Map.put(out, "progress_novalue", DOM.matches(q.("#p"), ":indeterminate"))
      out = Map.put(out, "progress_value", DOM.matches(q.("#p2"), ":indeterminate"))

      assert out == expected
    end
  end
end
