defmodule DOM.HTML.Token.Comment do
  @moduledoc "A comment token: `<!--data-->`."

  @enforce_keys [:data]
  defstruct [:data]

  use DOM.HTML.Token

  @type t :: %__MODULE__{data: String.t()}

  # Comment data is not subject to character-reference decoding.
  @impl DOM.HTML.Token
  def decode(%__MODULE__{} = token), do: token
end
