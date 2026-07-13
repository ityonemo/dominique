defmodule Integration.DetailsTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Event
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/interactive-elements.html#the-details-element"

    # Clicking a <summary> toggles the parent <details>'s open attribute (unless
    # preventDefault); :open matches the open state. We compare the open-attribute
    # sequence in Elixir against the browser.
    @js """
    return await page.evaluate(() => {
      const host = document.createElement("div");
      host.innerHTML = "<details id='d'><summary id='s'>t</summary>body</details>";
      document.body.appendChild(host);
      const d = host.querySelector("#d"), s = host.querySelector("#s");
      const click = () => s.dispatchEvent(new MouseEvent("click", {bubbles:true, cancelable:true}));

      const out = {};
      out.initial = d.hasAttribute("open");
      click(); out.after1 = d.hasAttribute("open");
      out.open_pseudo = d.matches(":open");
      click(); out.after2 = d.hasAttribute("open");
      document.body.removeChild(host);
      return out;
    });
    """

    test "details toggle + :open match the browser", %{js: expected} do
      doc = DOM.new("<body><details id='d'><summary id='s'>t</summary>body</details></body>")
      d = DOM.query_selector(doc, "#d")
      s = DOM.query_selector(doc, "#s")

      click = fn ->
        Node.dispatch_event(s, Event.new("click", bubbles: true, cancelable: true))
      end

      out = %{"initial" => Element.has_attribute(d, "open")}
      click.()
      out = Map.put(out, "after1", Element.has_attribute(d, "open"))
      out = Map.put(out, "open_pseudo", DOM.matches(d, ":open"))
      click.()
      out = Map.put(out, "after2", Element.has_attribute(d, "open"))

      assert out == expected
    end
  end
end
