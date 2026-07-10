defmodule DOM.IndexSizeError do
  @moduledoc """
  Raised when an index or offset is negative or greater than the allowed value —
  e.g. a Range boundary offset past a container's child count or text length.
  """

  defexception message: "The index is not in the allowed range."
end
