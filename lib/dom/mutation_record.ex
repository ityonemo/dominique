defmodule DOM.MutationRecord do
  @moduledoc """
  A single mutation reported to a `DOM.MutationObserver` callback (WHATWG
  `MutationRecord`). One record per mutation; the callback receives the batch.

  `type` is `:child_list | :attributes | :character_data`. Fields carry only what
  applies to the type:

    * `:child_list` — `added_nodes`, `removed_nodes`, `previous_sibling`,
      `next_sibling`, `target` (the parent whose children changed).
    * `:attributes` — `attribute_name`, `old_value` (nil unless the observer set
      `attribute_old_value`), `target`.
    * `:character_data` — `old_value` (nil unless `character_data_old_value`),
      `target`.

  Node fields are `DOM.Node` handles into the owning document.
  """

  alias DOM.Node

  @enforce_keys [:type, :target]
  defstruct [
    :type,
    :target,
    :attribute_name,
    :old_value,
    :previous_sibling,
    :next_sibling,
    added_nodes: [],
    removed_nodes: []
  ]

  @type t :: %__MODULE__{
          type: :child_list | :attributes | :character_data,
          target: Node.t(),
          attribute_name: String.t() | nil,
          old_value: String.t() | nil,
          previous_sibling: Node.t() | nil,
          next_sibling: Node.t() | nil,
          added_nodes: [Node.t()],
          removed_nodes: [Node.t()]
        }
end
