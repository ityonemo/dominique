defmodule DOM.CSS.Id do
  @moduledoc "An id selector such as `#main`."

  alias DOM.CSS.Serialize

  @enforce_keys [:name]
  defstruct [:name]

  use DOM.CSS

  @type t :: %__MODULE__{name: String.t()}

  @impl DOM.CSS
  def match(_selector, _nodes, _candidate_ids), do: raise("unimplemented")

  defimpl String.Chars do
    def to_string(%{name: name}), do: "#" <> Serialize.escape_ident(name)
  end
end
