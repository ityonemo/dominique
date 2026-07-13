defmodule DOM.Slot do
  @moduledoc """
  Reads over a `<slot>` element's assignment: the light-DOM nodes of the shadow
  host that project into this slot (named slotting). Assignment is maintained by
  the server; these are pure reads.
  """

  alias DOM.Node

  @doc "The nodes assigned to `slot` (light-tree order); `[]` when unassigned."
  @spec assigned_nodes(Node.t()) :: [Node.t()]
  def assigned_nodes(%Node{type: :element} = slot) do
    DOM._slot_assigned_nodes(slot.server, slot.node_id)
  end

  @doc "The assigned nodes filtered to elements."
  @spec assigned_elements(Node.t()) :: [Node.t()]
  def assigned_elements(%Node{type: :element} = slot) do
    slot |> assigned_nodes() |> Enum.filter(&(&1.type == :element))
  end

  @doc """
  Imperatively assign `nodes` to `slot` (the HTML `slot.assign(...)`). Only meaningful
  when the slot's shadow root is in `:manual` slot-assignment mode; it replaces any
  previous manual assignment (call with `[]` to clear). Only nodes that are light-DOM
  children of the shadow host are effectively assigned. Fires `slotchange`.
  """
  @spec assign(Node.t(), [Node.t()]) :: :ok
  def assign(%Node{type: :element} = slot, nodes) when is_list(nodes) do
    DOM._slot_assign(slot.server, slot.node_id, Enum.map(nodes, & &1.node_id))
  end
end
