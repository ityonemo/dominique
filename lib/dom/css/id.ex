defmodule DOM.CSS.Id do
  @moduledoc "An id selector such as `#main`."

  alias DOM.CSS.Query
  alias DOM.CSS.Serialize

  @enforce_keys [:name]
  defstruct [:name]

  use DOM.CSS

  @type t :: %__MODULE__{name: String.t()}

  @impl DOM.CSS
  def match(%{name: name}, nodes, candidate_ids) do
    Query.id(nodes, candidate_ids, name)
  end

  defimpl String.Chars do
    def to_string(%{name: name}), do: "#" <> Serialize.escape_ident(name)
  end
end
