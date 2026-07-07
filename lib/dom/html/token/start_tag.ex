defmodule DOM.HTML.Token.StartTag do
  @moduledoc "A start-tag token: `<name attr=\"v\" ...>` or self-closing `<name/>`."

  @enforce_keys [:name]
  defstruct [:name, attributes: [], self_closing: false]

  use DOM.HTML.Token

  alias DOM.HTML.Entities

  @type t :: %__MODULE__{
          name: String.t(),
          attributes: [{String.t(), String.t()}],
          self_closing: boolean()
        }

  @impl DOM.HTML.Token
  def decode(%__MODULE__{attributes: attributes} = token) do
    decoded =
      Enum.map(attributes, fn {name, value} ->
        {name, Entities.decode(value, attribute: true)}
      end)

    %{token | attributes: decoded}
  end
end
