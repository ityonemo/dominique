defmodule DOM.HTML.Token.Doctype do
  @moduledoc """
  A doctype token: `<!DOCTYPE name PUBLIC "..." "...">`. `public_id`/`system_id`
  are `nil` when absent. `force_quirks` is the WHATWG force-quirks flag
  (html5lib's `correctness` is its negation).
  """

  defstruct [:name, :public_id, :system_id, force_quirks: false]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          public_id: String.t() | nil,
          system_id: String.t() | nil,
          force_quirks: boolean()
        }
end
