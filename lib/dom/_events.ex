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
  alias DOM.NodeData.IndexTable
  alias DOM.NodeData.NodesTable

  # Dispatch `event` at `target_id`. Returns `not default_prevented` (the DOM's
  # dispatchEvent boolean). Runs in-server: `nodes`/`index` are the live tids,
  # `server` is the document pid (for building handles listeners receive).
  #
  # The propagation path is target..root (shadow-crossing when `event.composed`,
  # else stopping at the origin shadow root). Each path entry carries the RETARGETED
  # target for that node: shadow-internal nodes see the real target, light-DOM nodes
  # past a shadow boundary see the host. Phases:
  #   1. CAPTURING — root -> target-exclusive, capture listeners
  #   2. AT_TARGET — the target, both capture and bubble listeners
  #   3. BUBBLING  — target-exclusive -> root, bubble listeners (only if bubbles)
  # propagation_stopped halts between NODES; immediate_stopped halts between
  # listeners on one node. Both live in the ref-keyed :active_event row.
  @spec dispatch(:ets.tid(), :ets.tid(), GenServer.server(), reference(), Event.t()) :: boolean()
  def dispatch(nodes, index, server, target_id, %Event{} = event) do
    ref = make_ref()
    IndexTable.active_event_open(index, ref)
    event = %{event | ref: ref}

    # path = [{node_id, retarget_id}, ...] from target outward; the target entry
    # heads it, the rest are the (shadow-crossing) ancestors.
    [target_entry | ancestors] = propagation_path(nodes, target_id, event.composed)

    try do
      run_phase(nodes, index, server, Enum.reverse(ancestors), :capturing, event)
      run_phase(nodes, index, server, [target_entry], :at_target, event)

      if event.bubbles do
        run_phase(nodes, index, server, ancestors, :bubbling, event)
      end

      not IndexTable.active_event_flags(index, ref).default_prevented
    after
      IndexTable.active_event_close(index, ref)
    end
  end

  @doc """
  The composed path for an event dispatched at `target_id`: `[{node_id,
  retarget_id}, ...]` from the target outward to the root, crossing shadow
  boundaries only when `composed?`. The `retarget_id` is `event.target` as seen
  by a listener on that node (the host once past a shadow boundary).
  """
  @spec propagation_path(:ets.tid(), reference(), boolean()) :: [{reference(), reference()}]
  def propagation_path(nodes, target_id, composed?) do
    build_path(nodes, target_id, target_id, composed?, [])
  end

  # Walk parent-ward accumulating {node, retarget}. `retarget` is the current
  # visible target — the real target within a tree, re-set to the host each time a
  # shadow boundary is crossed. A boundary is a node whose `parent` is nil AND is a
  # shadow root: composed jumps to the host, non-composed stops.
  defp build_path(nodes, node_id, retarget, composed?, acc) do
    acc = [{node_id, retarget} | acc]

    case NodesTable.parent(nodes, node_id) do
      nil ->
        host = shadow_host_of(nodes, node_id)

        if composed? and host do
          # crossed a shadow boundary: the host becomes the visible target
          build_path(nodes, host, host, composed?, acc)
        else
          Enum.reverse(acc)
        end

      parent_id ->
        build_path(nodes, parent_id, retarget, composed?, acc)
    end
  end

  # The host of `node_id` when it is a shadow root, else nil (marks a boundary).
  defp shadow_host_of(nodes, node_id) do
    if NodesTable.type(nodes, node_id) == :shadow_root, do: NodesTable.shadow_host(nodes, node_id)
  end

  # Walk `path` (entries `{node_id, retarget_id}`) firing each node's
  # phase-appropriate listeners with the retargeted event.target. A no-op once
  # propagation_stopped is set — so a stop in the capture phase skips the target and
  # bubble phases too (checked before each node fires).
  defp run_phase(nodes, index, server, path, phase, event) do
    event = %{event | event_phase: Event.phase(phase)}

    Enum.reduce_while(path, :ok, fn {node_id, retarget_id}, _ ->
      if IndexTable.active_event_flags(index, event.ref).propagation_stopped do
        {:halt, :ok}
      else
        current = %{
          event
          | current_target: handle(nodes, server, node_id),
            target: handle(nodes, server, retarget_id)
        }

        fire_listeners(index, node_id, phase, current)
        {:cont, :ok}
      end
    end)

    :ok
  end

  # Which listeners fire in a phase: capture-phase fires capture:true, bubble-phase
  # fires capture:false, and AT_TARGET fires both (a target listener's capture flag
  # doesn't gate it).
  defp fires_in_phase?(_listener, :at_target), do: true
  defp fires_in_phase?(listener, :capturing), do: listener.capture
  defp fires_in_phase?(listener, :bubbling), do: not listener.capture

  # Invoke `node_id`'s listeners for the event type that fire in `phase`, in
  # registration order. Stops early on immediate_stopped. `once` listeners are
  # removed before firing.
  defp fire_listeners(index, node_id, phase, event) do
    index
    |> IndexTable.listeners_of(node_id)
    |> Enum.filter(&(&1.type == event.type and fires_in_phase?(&1, phase)))
    |> Enum.reduce_while(:ok, fn listener, _ ->
      if listener.once do
        IndexTable.listener_delete(index, node_id, listener.type, listener.fn, listener.capture)
      end

      call_listener(listener, event)

      if IndexTable.active_event_flags(index, event.ref).immediate_stopped,
        do: {:halt, :ok},
        else: {:cont, :ok}
    end)

    :ok
  end

  @doc """
  Fire `target_ref`'s listeners for `event` target-only — no capture/bubble, no tree
  walk. For an `EventTarget` that is not in the node tree (an `AbortSignal`): its
  listeners live in `:listener` rows keyed by `target_ref`, dispatched at-target.
  """
  @spec dispatch_to_target(:ets.tid(), reference(), Event.t()) :: :ok
  def dispatch_to_target(index, target_ref, %Event{} = event) do
    ref = make_ref()
    IndexTable.active_event_open(index, ref)
    event = %{event | ref: ref, target: target_ref}

    try do
      fire_listeners(index, target_ref, :at_target, event)
    after
      IndexTable.active_event_close(index, ref)
    end
  end

  # Run one listener's lambda with the event. Listener exceptions currently
  # propagate (crashing the server) — event-loop isolation is a later concern.
  defp call_listener(listener, event), do: listener.fn.(event)

  defp handle(nodes, server, node_id) do
    %DOM.Node{server: server, node_id: node_id, type: NodesTable.type(nodes, node_id)}
  end
end
