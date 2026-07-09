defmodule DOM.HTML.Token.Character do
  @moduledoc """
  A character token carrying a run of text data. The tokenizer coalesces
  consecutive characters into one token (the WHATWG tokenizer emits one per
  character).

  `decode?` records whether character references in `data` should be decoded —
  it is `false` for interiors captured in the RAWTEXT / script-data tokenizer
  states (script/style/xmp/iframe/noembed/noframes), where references are NOT
  consumed, and `true` for ordinary text and RCDATA (title/textarea). This is how
  the tokenizer-state dependence of decoding survives into `decode/1`, which is
  otherwise applied uniformly across the token stream.
  """

  @enforce_keys [:data]
  defstruct [:data, decode?: true]

  use DOM.HTML.Token

  alias DOM.HTML.Entities

  @type t :: %__MODULE__{data: String.t(), decode?: boolean()}

  @impl DOM.HTML.Token
  def decode(%__MODULE__{decode?: false} = token), do: token

  def decode(%__MODULE__{data: data} = token) do
    %{token | data: Entities.decode(data)}
  end
end
