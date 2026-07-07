defmodule DOM.HTML.Token.Character do
  @moduledoc """
  A character token carrying a run of text data. The tokenizer coalesces
  consecutive characters into one token (the WHATWG tokenizer emits one per
  character). Character references are left undecoded for now.
  """

  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: String.t()}
end
