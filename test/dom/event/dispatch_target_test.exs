defmodule DOM.Event.DispatchTargetTest do
  use DOM.Case, async: true

  # E2: DOM.Event + single-node dispatch_event (target phase only). Listeners run
  # in the server; a per-dispatch :active_event row holds the mutable Event state,
  # keyed by the ref carried in the handed-out Event struct. preventDefault flips
  # that row; dispatch_event returns `not default_prevented`. Fire order / effects
  # are observed by having listeners send to the (external) test pid.

  alias DOM.Event
  alias DOM.Node

  test "a target-registered listener fires with the event" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    me = self()

    Node.add_event_listener(d, "click", fn ev ->
      send(me, {:fired, ev.type, ev.current_target.node_id})
    end)

    assert Node.dispatch_event(d, Event.new("click"))
    assert_receive {:fired, "click", target_id}
    assert target_id == d.node_id
  end

  test "listeners fire in registration order" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    me = self()

    Node.add_event_listener(d, "click", fn _ -> send(me, :first) end)
    Node.add_event_listener(d, "click", fn _ -> send(me, :second) end)

    Node.dispatch_event(d, Event.new("click"))
    assert_receive :first
    assert_receive :second
  end

  test "only listeners for the dispatched type fire" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    me = self()

    Node.add_event_listener(d, "click", fn _ -> send(me, :click) end)
    Node.add_event_listener(d, "keydown", fn _ -> send(me, :keydown) end)

    Node.dispatch_event(d, Event.new("click"))
    assert_receive :click
    refute_receive :keydown
  end

  test "preventDefault makes dispatch_event return false (cancelable)" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")

    Node.add_event_listener(d, "click", fn ev -> Event.prevent_default(ev) end)

    refute Node.dispatch_event(d, Event.new("click", cancelable: true))
  end

  test "preventDefault on a non-cancelable event does not cancel" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")

    Node.add_event_listener(d, "click", fn ev -> Event.prevent_default(ev) end)

    # cancelable defaults to false — preventDefault is a no-op, so still returns true
    assert Node.dispatch_event(d, Event.new("click"))
  end

  test "dispatch_event returns true when nothing prevents default" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    Node.add_event_listener(d, "click", fn _ -> :ok end)

    assert Node.dispatch_event(d, Event.new("click", cancelable: true))
  end

  test "once listener fires exactly once then is removed" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    me = self()

    Node.add_event_listener(d, "click", fn _ -> send(me, :ping) end, once: true)

    Node.dispatch_event(d, Event.new("click"))
    Node.dispatch_event(d, Event.new("click"))

    assert_receive :ping
    refute_receive :ping
    assert Node.__listeners(d) == []
  end

  test "nested dispatch: a listener dispatching another event keeps states separate" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    me = self()

    # inner click cancels itself; outer custom must NOT be cancelled by that
    Node.add_event_listener(d, "click", fn ev -> Event.prevent_default(ev) end)

    Node.add_event_listener(d, "custom", fn _ev ->
      inner = Node.dispatch_event(d, Event.new("click", cancelable: true))
      # inner cancelled -> false; the outer event is unaffected
      send(me, {:inner_result, inner})
    end)

    outer = Node.dispatch_event(d, Event.new("custom", cancelable: true))
    assert_receive {:inner_result, false}
    # the outer custom event was never prevented
    assert outer
  end

  test "dispatch_event is callable re-entrantly (from inside the server)" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    me = self()
    Node.add_event_listener(d, "click", fn _ -> send(me, :fired) end)

    DOM.lambda(d.server, fn -> Node.dispatch_event(d, Event.new("click")) end)
    assert_receive :fired
  end
end
