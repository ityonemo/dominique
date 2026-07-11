defmodule DOM.Events do
  @moduledoc false

  # The event dispatch algorithm, run INSIDE the document server (listeners are
  # lambdas that execute here; they may call DOM ops re-entrantly). E2 implements
  # the target phase only; capture/bubble propagation is E3.
  #
  # A dispatch owns an `{:active_event, ref}` index row holding the mutable event
  # state; the ref travels in the DOM.Event handed to each listener so its
  # prevent_default/stop_* route back to this row. The row is opened on entry and
  # closed on exit (try/after, so a raising listener still cleans up).

  alias DOM.Event
  alias DOM.NodeData.Table

  # Dispatch `event` at `target_id`. Returns `not default_prevented` (the DOM's
  # dispatchEvent boolean). Runs in-server: `nodes`/`index` are the live tids,
  # `server` is the document pid (for building handles listeners receive).
  @spec dispatch(:ets.tid(), :ets.tid(), GenServer.server(), reference(), Event.t()) :: boolean()
  def dispatch(nodes, index, server, target_id, %Event{} = event) do
    ref = make_ref()
    Table.active_event_open(index, ref)

    target = handle(nodes, server, target_id)
    event = %{event | ref: ref, target: target}

    try do
      run_target(nodes, index, server, target_id, event)
      not Table.active_event_flags(index, ref).default_prevented
    after
      Table.active_event_close(index, ref)
    end
  end

  # Target phase: fire every listener registered on the target (both capture flags
  # fire AT_TARGET), in registration order, respecting stopImmediatePropagation.
  defp run_target(nodes, index, server, target_id, event) do
    event = %{
      event
      | current_target: handle(nodes, server, target_id),
        event_phase: Event.phase(:at_target)
    }

    fire_listeners(index, target_id, event)
  end

  # Invoke each of `node_id`'s listeners for the event type, in order. Stops early
  # if a listener set immediate_stopped. `once` listeners are removed before firing.
  defp fire_listeners(index, node_id, event) do
    index
    |> Table.listeners_of(node_id)
    |> Enum.filter(&(&1.type == event.type))
    |> Enum.reduce_while(:ok, fn listener, _ ->
      if listener.once do
        Table.listener_delete(index, node_id, listener.type, listener.fn, listener.capture)
      end

      call_listener(listener, event)

      if Table.active_event_flags(index, event.ref).immediate_stopped,
        do: {:halt, :ok},
        else: {:cont, :ok}
    end)

    :ok
  end

  # Run one listener's lambda with the event. Listener exceptions currently
  # propagate (crashing the server) — event-loop isolation is a later concern.
  defp call_listener(listener, event), do: listener.fn.(event)

  defp handle(nodes, server, node_id) do
    %DOM.Node{server: server, node_id: node_id, type: Table.type(nodes, node_id)}
  end
end
