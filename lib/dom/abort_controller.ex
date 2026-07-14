defmodule DOM.AbortController do
  @moduledoc """
  A DOM `AbortController` — an object with an `AbortSignal` (`signal/1`) and an
  `abort/1,2` method. Create with `DOM.AbortController.new/1`.

  `abort/2` marks the signal aborted, sweeps every event listener registered with
  that signal via the `{signal}` `addEventListener` option, fires the signal's
  `abort` event, and propagates to any composite signals (`DOM.AbortSignal.any/2`).

  The controller and its signal share one server-side state row (`{:abort_signal,
  ref}`); both handles stay valid as the row flips aborted, like `DOM.Range` /
  `DOM.TreeWalker`.
  """

  alias DOM.AbortSignal
  alias DOM.Node

  @enforce_keys [:server, :ref]
  defstruct [:server, :ref]

  @type t :: %__MODULE__{server: GenServer.server(), ref: reference()}

  @doc "Create a fresh `AbortController` (its signal is not aborted)."
  @spec new(Node.t()) :: t()
  def new(%Node{type: :document, server: server}) do
    ref = make_ref()
    DOM._abort_signal_create(server, ref)
    %__MODULE__{server: server, ref: ref}
  end

  @doc "The controller's `AbortSignal`."
  @spec signal(t()) :: AbortSignal.t()
  def signal(%__MODULE__{server: server, ref: ref}), do: %AbortSignal{server: server, ref: ref}

  @doc """
  Abort the controller's signal with `reason` (default an `AbortError`). Idempotent —
  aborting an already-aborted signal is a no-op.
  """
  @spec abort(t(), term()) :: :ok
  def abort(%__MODULE__{server: server, ref: ref}, reason \\ :abort_error) do
    DOM._abort_signal_abort(server, ref, reason)
  end
end
