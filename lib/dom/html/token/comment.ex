defmodule DOM.HTML.Token.Comment do
  @moduledoc "A comment token: `<!--data-->`."

  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: String.t()}
end
