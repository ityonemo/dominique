defmodule DOM.HTML.Token.Doctype do
  @moduledoc """
  A doctype token: `<!DOCTYPE name PUBLIC "..." "...">`. `public_id`/`system_id`
  are `nil` when absent. `force_quirks` is the WHATWG force-quirks flag
  (html5lib's `correctness` is its negation).
  """

  defstruct [:name, :public_id, :system_id, force_quirks: false]

  use DOM.HTML.Token

  @type t :: %__MODULE__{
          name: String.t() | nil,
          public_id: String.t() | nil,
          system_id: String.t() | nil,
          force_quirks: boolean()
        }

  @impl DOM.HTML.Token
  def decode(%__MODULE__{} = token), do: token
end
