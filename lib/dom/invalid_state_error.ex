defmodule DOM.InvalidStateError do
  @moduledoc """
  Raised when an object is in an invalid state for the requested operation — e.g.
  `Range.surroundContents` when the range partially selects a non-Text node.
  """

  defexception message: "The object is in an invalid state."
end
