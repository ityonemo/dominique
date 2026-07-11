defmodule Integration.EventTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Event
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#dispatching-events"

    # Target-phase dispatch: fire order, dispatchEvent's boolean return under
    # preventDefault (cancelable vs not), type filtering, and `once`.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString("<div id='d'></div>", "text/html");
      const d = doc.getElementById("d");
      const order = [];

      d.addEventListener("click", () => order.push("a"));
      d.addEventListener("click", () => order.push("b"));
      d.addEventListener("keydown", () => order.push("k"));

      const plain = d.dispatchEvent(new Event("click"));           // true
      const cancelHandler = (e) => e.preventDefault();

      d.addEventListener("cancelable", cancelHandler);
      const cancelled = d.dispatchEvent(new Event("cancelable", { cancelable: true }));   // false
      const notCancelable = d.dispatchEvent(new Event("cancelable"));                     // true (not cancelable)

      let onceCount = 0;
      d.addEventListener("boom", () => onceCount++, { once: true });
      d.dispatchEvent(new Event("boom"));
      d.dispatchEvent(new Event("boom"));

      return {
        order: order,          // ["a","b"] — keydown never fires on a click
        plain: plain,
        cancelled: cancelled,
        not_cancelable: notCancelable,
        once_count: onceCount
      };
    });
    """

    test "target-phase dispatch matches the browser", %{js: expected} do
      doc = DOM.new("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")
      me = self()

      Node.add_event_listener(d, "click", fn _ -> send(me, "a") end)
      Node.add_event_listener(d, "click", fn _ -> send(me, "b") end)
      Node.add_event_listener(d, "keydown", fn _ -> send(me, "k") end)

      plain = Node.dispatch_event(d, Event.new("click"))
      order = drain_order()

      Node.add_event_listener(d, "cancelable", fn ev -> Event.prevent_default(ev) end)
      cancelled = Node.dispatch_event(d, Event.new("cancelable", cancelable: true))
      not_cancelable = Node.dispatch_event(d, Event.new("cancelable"))

      {:ok, agent} = Agent.start_link(fn -> 0 end)
      Node.add_event_listener(d, "boom", fn _ -> Agent.update(agent, &(&1 + 1)) end, once: true)
      Node.dispatch_event(d, Event.new("boom"))
      Node.dispatch_event(d, Event.new("boom"))

      result = %{
        "order" => order,
        "plain" => plain,
        "cancelled" => cancelled,
        "not_cancelable" => not_cancelable,
        "once_count" => Agent.get(agent, & &1)
      }

      assert result == expected
    end
  end

  # Collect fire-order tokens the listeners sent to us, in order.
  defp drain_order(acc \\ []) do
    receive do
      token when is_binary(token) -> drain_order([token | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
