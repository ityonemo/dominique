defmodule DOM.Event.SelfRemovingListenerTest do
  use DOM.Case, async: true

  # A listener fires on the document server and OUTLIVES the process that registered
  # it. To bind a listener to a process's lifetime, register an arity-2 fn
  # `fn event, ref -> ... end` — the engine passes the listener's OWN ref when it
  # fires, so the listener can `remove_event_listener(node, ref)` itself once the
  # process it serves is gone. This is the "exfiltration listener" pattern.

  alias DOM.Event
  alias DOM.Node

  test "add_event_listener returns a ref" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")

    ref = Node.add_event_listener(d, "click", fn _ -> :ok end)
    assert is_reference(ref)
  end

  test "remove_event_listener(node, ref) removes by handle" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")

    ref = Node.add_event_listener(d, "click", fn _ -> :ok end)
    assert length(Node.__listeners(d)) == 1

    Node.remove_event_listener(d, ref)
    assert Node.__listeners(d) == []
  end

  test "an arity-2 listener receives its own ref when it fires" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    me = self()

    ref = Node.add_event_listener(d, "click", fn _event, ref -> send(me, {:fired_with, ref}) end)

    Node.dispatch_event(d, Event.new("click"))
    assert_receive {:fired_with, ^ref}
  end

  test "exfiltration listener: sends to its owner, self-detaches once the owner dies" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")

    # A collector we can observe; the guard process forwards to it while alive.
    {:ok, sink} = Agent.start_link(fn -> [] end)

    # The guarded owner: while alive it records each exfiltrated event into the sink.
    owner =
      spawn(fn ->
        receive_loop = fn loop ->
          receive do
            {:exfiltrate, tag} ->
              Agent.update(sink, &[tag | &1])
              loop.(loop)

            :stop ->
              :done
          end
        end

        receive_loop.(receive_loop)
      end)

    # An arity-2 listener that exfiltrates to `owner` and self-detaches when owner is dead.
    Node.add_event_listener(d, "click", fn _event, ref ->
      if Process.alive?(owner) do
        send(owner, {:exfiltrate, :click})
      else
        Node.remove_event_listener(d, ref)
      end
    end)

    # While the owner is alive: the listener fires and stays registered.
    Node.dispatch_event(d, Event.new("click"))
    Node.dispatch_event(d, Event.new("click"))
    # let the owner drain its mailbox
    :ok = wait_until(fn -> length(Agent.get(sink, & &1)) == 2 end)
    assert length(Node.__listeners(d)) == 1

    # Kill the owner; the next dispatch detects it dead and self-removes.
    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}

    Node.dispatch_event(d, Event.new("click"))
    assert Node.__listeners(d) == []

    # A further dispatch is a no-op (nothing registered) and does not exfiltrate.
    Node.dispatch_event(d, Event.new("click"))
    assert length(Agent.get(sink, & &1)) == 2
  end

  # Poll until `fun` is true (bounded), for the async owner mailbox drain.
  defp wait_until(fun, tries \\ 50)
  defp wait_until(_fun, 0), do: :timeout

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, tries - 1)
    end
  end
end
