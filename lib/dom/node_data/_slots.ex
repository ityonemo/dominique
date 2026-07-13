defmodule DOM.NodeData.Slots do
  @moduledoc false

  # Slot assignment: which light-DOM children of a shadow host project into which
  # `<slot>` of the host's shadow tree (named slotting). Assignment is MAINTAINED
  # as `:slot` rows in the index tid, recomputed for a host whenever its light
  # children or its shadow slots change. Rows:
  #   {{:slot, slot_id, position}, node_id}   -- assigned node at `position`
  #   {{:assigned, node_id}, slot_id}         -- inverse (a node's assigned slot)
  #
  # A light child's effective slot name is its `slot` attribute (default ""). A
  # `<slot>`'s name is its `name` attribute (default ""). The FIRST slot per name
  # (shadow tree order) gets that name's assignees, in host light-tree order.

  use MatchSpec

  alias DOM.NodeData
  alias DOM.NodeData.Table

  @doc """
  Recompute and store the `:slot`/`:assigned` rows for `host_id`'s shadow tree.
  Returns the ids of the slots whose assigned-node list actually CHANGED — the
  slots to signal `slotchange` on (empty when nothing changed).
  """
  @spec recompute(Table.tid(), Table.tid(), Table.id()) :: [Table.id()]
  def recompute(nodes, index, host_id) do
    shadow = Table.shadow_root(nodes, host_id)

    # Every slot that could be involved: those with an assignment before, plus the
    # slots present in the shadow tree now. Snapshot each before, mutate, diff after.
    slots =
      MapSet.new(prior_slot_ids(index, host_id))
      |> MapSet.union(MapSet.new(if shadow, do: slots_in(nodes, shadow), else: []))
      |> MapSet.to_list()

    before = Map.new(slots, &{&1, assigned_nodes(index, &1)})

    retract(index, host_id, shadow)
    if shadow, do: assign(nodes, index, host_id, shadow)

    for slot_id <- slots, assigned_nodes(index, slot_id) != Map.fetch!(before, slot_id) do
      slot_id
    end
  end

  # Drop the host's old assignment rows. The `:assigned_host` rows record every
  # (node -> slot) this host produced, so they drive cleanup of the `:slot` and
  # `:assigned` rows too — no dependence on the current slot set.
  defp retract(index, host_id, _shadow) do
    for {node_id, slot_id} <- prior_assignments(index, host_id) do
      :ets.match_delete(index, {{:slot, slot_id, :_}, node_id})
      :ets.match_delete(index, {{:assigned, node_id}, :_})
    end

    :ets.match_delete(index, {{:assigned_host, host_id, :_}, :_})
    :ok
  end

  # Compute + write the assignment for `host_id` into `shadow`. Branches on the shadow
  # root's slot-assignment mode: :named (default) matches light children to slots by
  # attribute; :manual uses each slot's explicitly-assigned nodes (slot.assign()).
  defp assign(nodes, index, host_id, shadow) do
    case Table.fetch!(nodes, shadow).slot_assignment do
      :manual -> assign_manual(nodes, index, host_id, shadow)
      _named -> assign_named(nodes, index, host_id, shadow)
    end
  end

  # Named mode: each light child projects into the first slot matching its slot name.
  # The reduce threads a per-slot position counter (its final value is discarded).
  defp assign_named(nodes, index, host_id, shadow) do
    slots = slots_in(nodes, shadow)
    slot_by_name = first_slot_per_name(nodes, slots)

    _final_positions =
      Enum.reduce(Table.children_by_extent(nodes, host_id), %{}, fn child, acc ->
        name = effective_slot_name(nodes, child)

        case Map.get(slot_by_name, name) do
          nil ->
            acc

          slot_id ->
            pos = Map.get(acc, slot_id, 0)
            write_assignment(index, host_id, slot_id, child, pos)
            Map.put(acc, slot_id, pos + 1)
        end
      end)

    :ok
  end

  # Manual mode: each slot receives its manually-assigned nodes (slot.assign()),
  # filtered to actual host light-DOM children, in assign order.
  defp assign_manual(nodes, index, host_id, shadow) do
    host_children = MapSet.new(Table.children_by_extent(nodes, host_id))

    for slot_id <- slots_in(nodes, shadow) do
      Table.fetch!(nodes, slot_id).manual_assigned
      |> Enum.filter(&MapSet.member?(host_children, &1))
      |> Enum.with_index()
      |> Enum.each(fn {child, pos} -> write_assignment(index, host_id, slot_id, child, pos) end)
    end

    :ok
  end

  defp write_assignment(index, host_id, slot_id, child, pos) do
    :ets.insert(index, {{:slot, slot_id, pos}, child})
    :ets.insert(index, {{:assigned, child}, slot_id})
    :ets.insert(index, {{:assigned_host, host_id, child}, slot_id})
    :ok
  end

  # ==========================================================================
  # Reads over the stored rows
  # ==========================================================================

  @doc "The assigned nodes of `slot_id`, in assignment (host light-tree) order."
  @spec assigned_nodes(Table.tid(), Table.id()) :: [Table.id()]
  def assigned_nodes(index, slot_id) do
    index
    |> :ets.select(assigned_nodes_spec(slot_id))
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defmatchspecp assigned_nodes_spec(slot_id) do
    {{:slot, ^slot_id, pos}, node_id} -> {pos, node_id}
  end

  @doc "The slot `node_id` is assigned to, or nil."
  @spec assigned_slot(Table.tid(), Table.id()) :: Table.id() | nil
  def assigned_slot(index, node_id) do
    case :ets.select(index, assigned_slot_spec(node_id)) do
      [slot_id] -> slot_id
      [] -> nil
    end
  end

  defmatchspecp assigned_slot_spec(node_id) do
    {{:assigned, ^node_id}, slot_id} -> slot_id
  end

  # ==========================================================================
  # Structural helpers
  # ==========================================================================

  @doc "The `<slot>` element ids in `shadow_root_id`'s tree, in document order."
  @spec slots_in(Table.tid(), Table.id()) :: [Table.id()]
  def slots_in(nodes, shadow_root_id) do
    Table.elements_by_tag_name(nodes, shadow_root_id, "slot")
  end

  @doc """
  The host id a slot belongs to: the slot's shadow-root's host. Walks the slot up
  to its tree root (a ShadowRoot), then reads its host.
  """
  @spec host_of_slot(Table.tid(), Table.id()) :: Table.id() | nil
  def host_of_slot(nodes, slot_id) do
    root = tree_root(nodes, slot_id)

    case Table.fetch!(nodes, root) do
      %NodeData.ShadowRoot{host: host} -> host
      _ -> nil
    end
  end

  @doc "Whether `id` is an element that currently hosts a shadow root."
  @spec shadow_host?(Table.tid(), Table.id()) :: boolean()
  def shadow_host?(nodes, id) do
    match?(%NodeData.Element{shadow_root: s} when s != nil, Table.fetch!(nodes, id))
  end

  @doc """
  The shadow host whose slot assignment `node_id` can affect: its parent if that
  parent hosts a shadow (a light child's `slot=` changed), else the host of the
  shadow tree `node_id` lives in (a `<slot>`'s `name=` changed). `nil` if neither.
  """
  @spec affected_host(Table.tid(), Table.id()) :: Table.id() | nil
  def affected_host(nodes, node_id) do
    parent = Table.parent(nodes, node_id)

    if parent && shadow_host?(nodes, parent) do
      parent
    else
      host_of_slot(nodes, node_id)
    end
  end

  # First `<slot>` per name (default "" for a nameless slot), shadow tree order.
  defp first_slot_per_name(nodes, slots) do
    Enum.reduce(slots, %{}, fn slot_id, acc ->
      name = slot_name(nodes, slot_id)
      Map.put_new(acc, name, slot_id)
    end)
  end

  defp slot_name(nodes, slot_id), do: Table.get_attribute(nodes, slot_id, "name") || ""

  defp effective_slot_name(nodes, node_id) do
    case Table.fetch!(nodes, node_id) do
      %NodeData.Element{} -> Table.get_attribute(nodes, node_id, "slot") || ""
      # non-element nodes (text) have no slot attribute -> the default slot
      _ -> ""
    end
  end

  defp tree_root(nodes, id) do
    case Table.parent(nodes, id) do
      nil -> id
      parent -> tree_root(nodes, parent)
    end
  end

  # The (node, slot) pairs previously assigned under `host_id`.
  defp prior_assignments(index, host_id) do
    :ets.select(index, prior_assignments_spec(host_id))
  end

  defmatchspecp prior_assignments_spec(host_id) do
    {{:assigned_host, ^host_id, node_id}, slot_id} -> {node_id, slot_id}
  end

  # The distinct slot ids that had an assignment under `host_id` before a recompute.
  defp prior_slot_ids(index, host_id) do
    index
    |> :ets.select(prior_slot_ids_spec(host_id))
    |> Enum.uniq()
  end

  defmatchspecp prior_slot_ids_spec(host_id) do
    {{:assigned_host, ^host_id, _node_id}, slot_id} -> slot_id
  end
end
