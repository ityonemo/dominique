defmodule DOM.HTML.Token.StartTag do
  @moduledoc "A start-tag token: `<name attr=\"v\" ...>` or self-closing `<name/>`."

  @enforce_keys [:name]
  defstruct [:name, attributes: [], self_closing: false]

  @type t :: %__MODULE__{
          name: String.t(),
          attributes: [{String.t(), String.t()}],
          self_closing: boolean()
        }
end
