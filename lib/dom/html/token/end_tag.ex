defmodule DOM.HTML.Token.EndTag do
  @moduledoc "An end-tag token: `</name>`."

  @enforce_keys [:name]
  defstruct [:name]

  use DOM.HTML.Token

  @type t :: %__MODULE__{name: String.t()}

  @impl DOM.HTML.Token
  def decode(%__MODULE__{} = token), do: token
end
