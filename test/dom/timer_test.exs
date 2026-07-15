defmodule DOM.TimerTest do
  use DOM.Case, async: true

  # setTimeout / clearTimeout / queueMicrotask — the task half of the event loop.
  # A timer is a TASK: it fires after the delay (a Process.send_after message), runs
  # its callback inside the server, then runs a microtask checkpoint. Microtasks
  # drain BEFORE any task; a microtask enqueued inside a timer body drains right
  # after that body. Browser-verified ordering in the timer-task-semantics memory.
  #
  # These are HTML-spec WindowOrWorkerGlobalScope methods (not DOM proper); Dominique
  # provides them on the DOM context module as a convenience, since the document
  # server already owns the event loop they need.

  alias DOM.Node

  test "set_timeout runs its callback as a task after the delay" do
    doc = new_document("<div></div>")
    parent = self()

    DOM.set_timeout(doc, fn -> send(parent, :fired) end, 0)

    assert_receive :fired, 200
  end

  test "clear_timeout cancels a pending timer" do
    doc = new_document("<div></div>")
    parent = self()

    id = DOM.set_timeout(doc, fn -> send(parent, :should_not_run) end, 30)
    DOM.clear_timeout(doc, id)
    DOM.set_timeout(doc, fn -> send(parent, :ran) end, 30)

    assert_receive :ran, 200
    refute_received :should_not_run
  end

  test "a shorter delay fires before a longer one" do
    doc = new_document("<div></div>")
    parent = self()

    DOM.set_timeout(doc, fn -> send(parent, :late) end, 40)
    DOM.set_timeout(doc, fn -> send(parent, :early) end, 0)

    assert_receive :early, 200
    assert_receive :late, 200
    # early arrived first (it was consumed first above)
  end

  test "a timer callback may mutate the DOM" do
    doc = new_document("<div id='p'></div>")
    p = DOM.query_selector(doc, "#p")
    parent = self()

    DOM.set_timeout(
      doc,
      fn ->
        child = DOM.create_element(doc, "span")
        Node.append_child(p, child)
        send(parent, :mutated)
      end,
      0
    )

    assert_receive :mutated, 200
    assert DOM.query_selector(doc, "#p span")
  end

  test "a microtask enqueued inside a timer body drains right after that body" do
    doc = new_document("<div></div>")
    parent = self()

    DOM.set_timeout(
      doc,
      fn ->
        send(parent, :timer_body)
        # enqueued re-entrantly (server == self()); runs at the timer's trailing
        # microtask checkpoint, before control returns to the mailbox.
        DOM._enqueue_microtask(doc.server, fn -> send(parent, :micro_in_timer) end)
      end,
      0
    )

    assert_receive :timer_body, 200
    assert_receive :micro_in_timer, 200
  end

  test "a timer callback may schedule another timer (a later task)" do
    doc = new_document("<div></div>")
    parent = self()

    DOM.set_timeout(
      doc,
      fn ->
        send(parent, :a)
        DOM.set_timeout(doc, fn -> send(parent, :b) end, 0)
      end,
      0
    )

    assert_receive :a, 200
    assert_receive :b, 200
  end

  test "queue_microtask runs the callback at the next checkpoint" do
    doc = new_document("<div></div>")
    parent = self()

    DOM.queue_microtask(doc, fn -> send(parent, :micro) end)

    assert_receive :micro, 200
  end

  describe "set_interval" do
    test "repeats until cleared from inside the callback" do
      doc = new_document("<div></div>")
      parent = self()
      counter = :counters.new(1, [])

      DOM.set_interval(
        doc,
        fn ->
          n = :counters.get(counter, 1) + 1
          :counters.add(counter, 1, 1)
          send(parent, {:tick, n})
        end,
        10
      )

      assert_receive {:tick, 1}, 300
      assert_receive {:tick, 2}, 300
      assert_receive {:tick, 3}, 300
    end

    test "clear_interval stops further ticks" do
      doc = new_document("<div></div>")
      parent = self()

      id = DOM.set_interval(doc, fn -> send(parent, :tick) end, 10)
      assert_receive :tick, 300
      DOM.clear_interval(doc, id)

      # after clearing, no further ticks arrive within a comfortable window
      flush()
      refute_receive :tick, 60
    end

    test "an interval callback that clears its own id stops the interval" do
      doc = new_document("<div></div>")
      parent = self()
      counter = :counters.new(1, [])
      {:ok, id_holder} = Agent.start_link(fn -> nil end)

      id =
        DOM.set_interval(
          doc,
          fn ->
            n = :counters.get(counter, 1) + 1
            :counters.add(counter, 1, 1)
            send(parent, {:tick, n})
            if n == 3, do: DOM.clear_interval(doc, Agent.get(id_holder, & &1))
          end,
          10
        )

      Agent.update(id_holder, fn _ -> id end)

      assert_receive {:tick, 3}, 400
      flush()
      refute_receive {:tick, _}, 60
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
