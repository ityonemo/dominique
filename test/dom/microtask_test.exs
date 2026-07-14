defmodule DOM.MicrotaskTest do
  use DOM.Case, async: true

  # M1: the microtask queue primitive. A microtask is a one-shot deferred lambda
  # run at the microtask checkpoint — the HTML event loop's "perform a microtask
  # checkpoint", which drains the queue AFTER the current task (an outermost DOM
  # operation) completes, before control returns to the caller's next task.
  #
  # We observe timing by sending tags to the test process (self()) from inside the
  # lambdas: the ORDER of received messages is the drain order. We use assert_receive
  # (blocking) rather than assert_received (instantaneous) because the checkpoint runs
  # in a separate handle_continue AFTER the enqueuing call has replied — so the
  # enqueuing call returning does NOT mean the drain has finished; an observer must
  # wait. assert_receive consumes messages in mailbox (send) order, so a sequence of
  # assert_receive still asserts drain ORDER.
  #
  # There is no browser oracle here: the checkpoint's internal timing is not
  # observable through a single JS call, and this arc ships no DOM customer yet
  # (slotchange is a later arc). These are pure Elixir invariants of the primitive.

  alias DOM.Event
  alias DOM.Node

  # _enqueue_microtask/2 called from OUTSIDE the server (the test process) exercises
  # the real GenServer.call → {:continue, :drain} → checkpoint path.
  defp enqueue(server, tag) do
    parent = self()
    DOM._enqueue_microtask(server, fn -> send(parent, tag) end)
  end

  # Collect `n` tags from the mailbox in arrival (drain) order. Each recv blocks up
  # to the ExUnit default, so it waits out the async checkpoint.
  defp collect(n) do
    for _ <- 1..n do
      receive do
        tag -> tag
      after
        200 -> flunk("expected #{n} microtask tags, mailbox ran dry")
      end
    end
  end

  test "microtasks drain in FIFO (enqueue) order, after the enqueuing call returns" do
    doc = new_document("<div id='d'></div>")

    enqueue(doc.server, :a)
    enqueue(doc.server, :b)
    enqueue(doc.server, :c)

    # Each enqueue is its own task with its own checkpoint; the tags arrive in the
    # order they were enqueued.
    assert collect(3) == [:a, :b, :c]
  end

  test "a microtask that enqueues another drains both in the same checkpoint, in order" do
    doc = new_document("<div id='d'></div>")
    parent = self()

    DOM._enqueue_microtask(doc.server, fn ->
      send(parent, :outer)
      # Enqueued from INSIDE the running microtask (server == self()): it must run
      # later in THIS same checkpoint drain, not spill to a separate task.
      DOM._enqueue_microtask(doc.server, fn -> send(parent, :inner) end)
    end)

    assert collect(2) == [:outer, :inner]
  end

  test "a re-entrant enqueue (from inside an op) defers past that op's body" do
    doc = new_document("<div id='d'></div>")
    parent = self()

    # Run INSIDE the server (server == self()), the condition a listener runs under.
    # The lambda enqueues a microtask, then sends :op_done. The microtask must NOT
    # run during the lambda body — it runs at the checkpoint after the op returns —
    # so :op_done is sent before :micro is.
    DOM.lambda(doc.server, fn ->
      DOM._enqueue_microtask(doc.server, fn -> send(parent, :micro) end)
      send(parent, :op_done)
    end)

    # :op_done is sent inside the op body; :micro only at the checkpoint after the
    # op returns — so the op-body message strictly precedes the microtask.
    assert collect(2) == [:op_done, :micro]
  end

  test "a dispatch enqueued in a microtask runs at the checkpoint, after the enqueuing op" do
    doc = new_document("<div id='t'></div>")
    target = DOM.query_selector(doc, "#t")
    parent = self()

    Node.add_event_listener(target, "ping", fn _event -> send(parent, :listener_fired) end)

    # The microtask body dispatches an event; its listener must fire during the
    # drain, after the enqueuing call already replied.
    DOM._enqueue_microtask(doc.server, fn ->
      send(parent, :microtask_ran)
      Node.dispatch_event(target, Event.new("ping"))
    end)

    assert collect(2) == [:microtask_ran, :listener_fired]
  end

  test "an operation that enqueues nothing drains an empty queue cleanly" do
    doc = new_document("<div id='d'></div>")
    # A plain op with no microtask still completes and returns normally.
    assert DOM.query_selector(doc, "#d")
    # And a bare enqueue-nothing checkpoint (via a lambda that does nothing) is a no-op.
    assert DOM.lambda(doc.server, fn -> :nothing end) == :nothing
  end

  test "check_consistency! raises if a microtask row is pending (checkpoint skipped)" do
    # Outside a checkpoint drain the queue must be empty; a surviving :microtask row
    # means a checkpoint was skipped. We stage that state by enqueuing AND running the
    # check inside ONE in-server lambda, before any drain fires: the row is present,
    # so check_consistency! must raise. (This uses a standalone server we tear down
    # ourselves — it deliberately leaves a row that would otherwise trip DOM.Case's
    # exit net, so it does not use the consistency-armed new_document.)
    document_id = make_ref()
    {:ok, server} = GenServer.start(DOM, document_id: document_id)

    caught =
      DOM.lambda(server, fn ->
        DOM._enqueue_microtask(server, fn -> :never_drained end)

        try do
          DOM.NodeData.check_consistency!(Process.get(:nodes), Process.get(:index))
          :no_raise
        rescue
          e in RuntimeError -> e.message
        end
      end)

    assert caught =~ "undrained microtask"

    GenServer.stop(server)
  end

  test "after a normal checkpoint the queue is empty and check_consistency! passes" do
    doc = new_document("<div id='d'></div>")
    parent = self()

    DOM._enqueue_microtask(doc.server, fn -> send(parent, :ran) end)
    assert collect(1) == [:ran]

    # The drain has completed (its message arrived), so the queue is empty and the
    # net passes — this is the invariant the whole suite relies on implicitly.
    assert DOM._check_index_consistency!(doc.server) == :ok
  end
end
