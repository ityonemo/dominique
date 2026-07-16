defmodule DOM.Listener do
  @moduledoc false

  # An event listener registered on a node, stored as the value of a `:listener`
  # index row (`{{:listener, node_id, seq}, %DOM.Listener{}}`). The lambda lives in
  # the ETS value; it is never serialized or cloned (listeners do not survive
  # cloneNode or cross-document adoption). Removal identity is `(type, fn, capture)`
  # — the same fn term passed to add/removeEventListener compares equal by
  # reference, matching the DOM's identity semantics — OR the listener's own `ref`
  # (the handle returned by add_event_listener, also injected into an arity-2 fn so
  # a running listener can remove itself). `ref` does NOT key the ordered_set row
  # (refs are not order-stable — `seq` is the order key); it is a stored handle.

  @enforce_keys [:type, :fn]
  defstruct [:type, :fn, :ref, capture: false, once: false, passive: false, signal_ref: nil]

  @type t :: %__MODULE__{
          type: String.t(),
          fn: (DOM.Event.t() -> any()) | (DOM.Event.t(), reference() -> any()),
          # The listener's own handle — returned by add_event_listener and passed as the
          # 2nd arg to an arity-2 fn. Removable via remove_event_listener(node, ref).
          ref: reference() | nil,
          capture: boolean(),
          once: boolean(),
          passive: boolean(),
          # The AbortSignal ref this listener was registered with (`{signal}` option),
          # or nil. When that signal aborts, every listener carrying its ref is swept.
          signal_ref: reference() | nil
        }
end
