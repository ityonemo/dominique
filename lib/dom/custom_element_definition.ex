defmodule DOM.CustomElementDefinition do
  @moduledoc """
  A custom-element definition — the Elixir stand-in for the JS class passed to
  `customElements.define`. A set of lifecycle callbacks plus `observed_attributes`.

  Register with `DOM.define_element/3`. Reactions run **synchronously** with their
  trigger (like a browser: `connected` fires during `appendChild`, not deferred):

    * `constructed(element)` — at `create_element` for a defined name, and first on
      upgrade (the "created"/constructor reaction).
    * `connected(element)` — when the element is inserted into a document tree.
    * `disconnected(element)` — when it is removed.
    * `attribute_changed(element, name, old, new)` — on every `setAttribute` /
      `removeAttribute` of a name in `observed_attributes` (fires even when the value
      is unchanged, matching the browser). `old`/`new` are the values (nil when absent).
    * `adopted(element, old_document, new_document)` — when the element is moved to a
      different document via `DOM.adopt_node/2`. Each document has its own registry, so
      the DESTINATION document's definition governs this callback.

  Each callback receives the element as a `DOM.Node` handle and may itself mutate the
  tree. A `nil` callback is simply not run. `observed_attributes` gates which attribute
  names trigger `attribute_changed`.
  """

  alias DOM.Node

  defstruct observed_attributes: [],
            constructed: nil,
            connected: nil,
            disconnected: nil,
            attribute_changed: nil,
            adopted: nil

  @type callback :: (Node.t() -> any())

  @type t :: %__MODULE__{
          observed_attributes: [String.t()],
          constructed: callback() | nil,
          connected: callback() | nil,
          disconnected: callback() | nil,
          attribute_changed:
            (Node.t(), String.t(), String.t() | nil, String.t() | nil -> any())
            | nil,
          adopted: (Node.t(), Node.t(), Node.t() -> any()) | nil
        }
end
