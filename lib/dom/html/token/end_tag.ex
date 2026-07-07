defmodule DOM.HTML.Token.EndTag do
  @moduledoc "An end-tag token: `</name>`."

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}
end
