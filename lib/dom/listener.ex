defmodule DOM.Listener do
  @moduledoc false

  # An event listener registered on a node, stored as the value of a `:listener`
  # index row (`{{:listener, node_id, seq}, %DOM.Listener{}}`). The lambda lives in
  # the ETS value; it is never serialized or cloned (listeners do not survive
  # cloneNode or cross-document adoption). Removal identity is `(type, fn, capture)`
  # — the same fn term passed to add/removeEventListener compares equal by
  # reference, matching the DOM's identity semantics.

  @enforce_keys [:type, :fn]
  defstruct [:type, :fn, capture: false, once: false, passive: false, signal_ref: nil]

  @type t :: %__MODULE__{
          type: String.t(),
          fn: (DOM.Event.t() -> any()),
          capture: boolean(),
          once: boolean(),
          passive: boolean(),
          # The AbortSignal ref this listener was registered with (`{signal}` option),
          # or nil. When that signal aborts, every listener carrying its ref is swept.
          signal_ref: reference() | nil
        }
end
