defmodule DOM.Event.PropagationTest do
  use DOM.Case, async: true

  # E3: full capture -> target -> bubble propagation. Fire order across the ancestor
  # chain, phase reporting, bubbles gating, and the two stop semantics. Listeners
  # record (label, phase) tuples to the test pid so order is observable.

  alias DOM.Event
  alias DOM.Node

  # <a id=gp><b id=p><c id=t></c></b></a> — grandparent > parent > target
  defp tree do
    doc = new_document("<a id='gp'><b id='p'><c id='t'></c></b></a>")

    {doc, DOM.query_selector(doc, "#gp"), DOM.query_selector(doc, "#p"),
     DOM.query_selector(doc, "#t")}
  end

  defp record(node, label, phase_flag) do
    me = self()

    Node.add_event_listener(node, "x", fn ev -> send(me, {label, ev.event_phase}) end,
      capture: phase_flag
    )
  end

  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "capture then target then bubble, in path order" do
    {_doc, gp, p, t} = tree()

    record(gp, :gp, true)
    record(p, :p, true)
    record(t, :t_capture, true)
    record(t, :t_bubble, false)
    record(p, :p_bubble, false)
    record(gp, :gp_bubble, false)

    Node.dispatch_event(t, Event.new("x", bubbles: true))

    # eventPhase: CAPTURING 1, AT_TARGET 2, BUBBLING 3
    assert drain() == [
             {:gp, 1},
             {:p, 1},
             {:t_capture, 2},
             {:t_bubble, 2},
             {:p_bubble, 3},
             {:gp_bubble, 3}
           ]
  end

  test "a non-bubbling event stops after the target phase" do
    {_doc, gp, p, t} = tree()

    record(gp, :gp, true)
    record(t, :t, false)
    record(p, :p_bubble, false)

    Node.dispatch_event(t, Event.new("x"))

    # capture reaches gp, target fires, but no bubble to p
    assert drain() == [{:gp, 1}, {:t, 2}]
  end

  test "stopPropagation halts after the current node's listeners" do
    {_doc, gp, p, t} = tree()
    me = self()

    # p's capture listener stops propagation; gp already fired, t/bubble must not
    record(gp, :gp, true)

    Node.add_event_listener(
      p,
      "x",
      fn ev ->
        send(me, {:p, ev.event_phase})
        Event.stop_propagation(ev)
      end,
      capture: true
    )

    record(t, :t, true)
    record(gp, :gp_bubble, false)

    Node.dispatch_event(t, Event.new("x", bubbles: true))

    assert drain() == [{:gp, 1}, {:p, 1}]
  end

  test "stopImmediatePropagation halts the current node's remaining listeners too" do
    {_doc, _gp, _p, t} = tree()
    me = self()

    Node.add_event_listener(t, "x", fn ev ->
      send(me, :first)
      Event.stop_immediate_propagation(ev)
    end)

    Node.add_event_listener(t, "x", fn _ -> send(me, :second) end)

    Node.dispatch_event(t, Event.new("x"))
    assert drain() == [:first]
  end

  test "a capture listener does not fire in the bubble phase and vice versa" do
    {_doc, _gp, p, t} = tree()
    me = self()

    Node.add_event_listener(p, "x", fn _ -> send(me, :p_capture) end, capture: true)
    Node.add_event_listener(p, "x", fn _ -> send(me, :p_bubble) end, capture: false)

    Node.dispatch_event(t, Event.new("x", bubbles: true))

    # capture pass hits p (capture listener), bubble pass hits p (bubble listener)
    assert drain() == [:p_capture, :p_bubble]
  end
end
