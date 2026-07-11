defmodule DOM.Event do
  @moduledoc """
  A DOM event. `new/2` builds one; `DOM.Node.dispatch_event/2` dispatches it.

  During dispatch the event's MUTABLE state (`default_prevented`, propagation
  flags) lives in an `{:active_event, ref}` index row, not in this struct — the
  struct is an immutable handle carrying that `ref`. Because listeners run inside
  the document server, `prevent_default/1` & the `stop_*` functions are re-entrant
  ETS updates to that row (routed by `ref`), so the dispatch loop sees them between
  listeners. `ref` is `nil` on a freshly-built event and is stamped per dispatch,
  which is what keeps NESTED dispatches (a listener dispatching another event)
  from clobbering each other — each live event has its own ref-keyed row.

  Read-only per-step fields (`target`, `current_target`, `event_phase`) are set by
  the dispatch loop and reflected into the copy each listener receives.
  """

  alias DOM.Node

  # eventPhase constants (DOM): NONE 0, CAPTURING 1, AT_TARGET 2, BUBBLING 3.
  @phase %{none: 0, capturing: 1, at_target: 2, bubbling: 3}

  @enforce_keys [:type]
  defstruct [
    :type,
    :ref,
    :target,
    :current_target,
    bubbles: false,
    cancelable: false,
    composed: false,
    event_phase: 0
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          ref: reference() | nil,
          target: Node.t() | nil,
          current_target: Node.t() | nil,
          bubbles: boolean(),
          cancelable: boolean(),
          composed: boolean(),
          event_phase: 0..3
        }

  @doc """
  Build an event of `type`. Options: `:bubbles`, `:cancelable`, `:composed` (all
  default `false`, matching `new Event(type)`).
  """
  @spec new(String.t(), keyword()) :: t()
  def new(type, opts \\ []) when is_binary(type) do
    %__MODULE__{
      type: type,
      bubbles: Keyword.get(opts, :bubbles, false),
      cancelable: Keyword.get(opts, :cancelable, false),
      composed: Keyword.get(opts, :composed, false)
    }
  end

  @doc "The numeric eventPhase constant for a phase atom."
  @spec phase(:none | :capturing | :at_target | :bubbling) :: 0..3
  def phase(atom), do: Map.fetch!(@phase, atom)

  @doc """
  Cancel the event's default action (only if it is `cancelable`). Sets the
  active event's `default_prevented` flag, so `dispatch_event` returns `false`.
  A no-op outside dispatch or on a non-cancelable event.
  """
  @spec prevent_default(t()) :: :ok
  def prevent_default(%__MODULE__{ref: nil}), do: :ok
  def prevent_default(%__MODULE__{cancelable: false}), do: :ok

  def prevent_default(%__MODULE__{ref: ref} = event) do
    DOM._event_set_flag(server(event), ref, :default_prevented)
  end

  @doc "Stop propagation after the current node's listeners (capture/bubble)."
  @spec stop_propagation(t()) :: :ok
  def stop_propagation(%__MODULE__{ref: nil}), do: :ok

  def stop_propagation(%__MODULE__{ref: ref} = event) do
    DOM._event_set_flag(server(event), ref, :propagation_stopped)
  end

  @doc "Stop propagation AND the current node's remaining listeners, immediately."
  @spec stop_immediate_propagation(t()) :: :ok
  def stop_immediate_propagation(%__MODULE__{ref: nil}), do: :ok

  def stop_immediate_propagation(%__MODULE__{ref: ref} = event) do
    # Per spec, this stops the current node's remaining listeners AND propagation to
    # further nodes — set both flags.
    DOM._event_set_flag(server(event), ref, :immediate_stopped)
    DOM._event_set_flag(server(event), ref, :propagation_stopped)
  end

  # The dispatching server: read off whichever node the loop set as target /
  # current_target (both live on the same server during dispatch).
  defp server(%__MODULE__{current_target: %Node{server: s}}), do: s
  defp server(%__MODULE__{target: %Node{server: s}}), do: s
end
