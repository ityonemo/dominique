defmodule DOM.AbortSignal do
  @moduledoc """
  A DOM `AbortSignal` — the read-only signal owned by an `DOM.AbortController` (or a
  standalone signal from `timeout/2` / `any/2`). Reflects whether an abort was
  requested (`aborted?/1`) and its `reason/1`.

  An `AbortSignal` is an `EventTarget` (it fires a single `abort` event when it
  aborts), but NOT a `DOM.Node` — so it carries its own thin listener surface
  (`add_event_listener/3`, `remove_event_listener/3`) reusing the same server-side
  `:listener` rows keyed by the signal ref, dispatched target-only (no capture/bubble).
  """

  alias DOM.Node

  @enforce_keys [:server, :ref]
  defstruct [:server, :ref]

  @type t :: %__MODULE__{server: GenServer.server(), ref: reference()}

  @doc "Whether the signal has been aborted."
  @spec aborted?(t()) :: boolean()
  def aborted?(%__MODULE__{server: server, ref: ref}), do: DOM._abort_signal_aborted?(server, ref)

  @doc "The abort reason (`nil` while not aborted)."
  @spec reason(t()) :: term()
  def reason(%__MODULE__{server: server, ref: ref}), do: DOM._abort_signal_reason(server, ref)

  @doc "Raise the abort reason if the signal is aborted; otherwise do nothing."
  @spec throw_if_aborted(t()) :: :ok
  def throw_if_aborted(%__MODULE__{} = signal) do
    if aborted?(signal), do: raise(DOM.AbortError, reason(signal)), else: :ok
  end

  @doc """
  A standalone `AbortSignal` that aborts (reason: a `TimeoutError`) after `ms`
  milliseconds — HTML `AbortSignal.timeout(ms)`, backed by `DOM.set_timeout/3`.
  """
  @spec timeout(Node.t(), non_neg_integer()) :: t()
  def timeout(%Node{type: :document, server: server} = document, ms) do
    ref = make_ref()
    DOM._abort_signal_create(server, ref)

    DOM.set_timeout(
      document,
      fn -> DOM._abort_signal_abort(server, ref, :timeout_error) end,
      ms
    )

    %__MODULE__{server: server, ref: ref}
  end

  @doc """
  A composite `AbortSignal` that aborts as soon as ANY of `signals` aborts, adopting
  that source's reason — DOM `AbortSignal.any(signals)`. If a source is already
  aborted, the composite is created already-aborted.
  """
  @spec any(Node.t(), [t()]) :: t()
  def any(%Node{type: :document, server: server}, signals) do
    ref = make_ref()
    source_refs = Enum.map(signals, & &1.ref)
    DOM._abort_signal_create_any(server, ref, source_refs)
    %__MODULE__{server: server, ref: ref}
  end

  @doc """
  Register `fun` as an `abort`-event listener on the signal (its only event). Fires
  target-only when the signal aborts. `opts` accepts `:once`.
  """
  @spec add_event_listener(t(), String.t(), (DOM.Event.t() -> any()), keyword()) :: :ok
  def add_event_listener(%__MODULE__{server: server, ref: ref}, type, fun, opts \\ [])
      when is_binary(type) and is_function(fun, 1) do
    listener = %DOM.Listener{type: type, fn: fun, once: Keyword.get(opts, :once, false)}
    DOM._abort_signal_add_listener(server, ref, listener)
  end

  @doc "Remove the `(type, fun)` listener from the signal."
  @spec remove_event_listener(t(), String.t(), (DOM.Event.t() -> any())) :: :ok
  def remove_event_listener(%__MODULE__{server: server, ref: ref}, type, fun)
      when is_binary(type) and is_function(fun, 1) do
    DOM._abort_signal_remove_listener(server, ref, type, fun)
  end
end
