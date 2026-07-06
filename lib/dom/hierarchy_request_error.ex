defmodule DOM.HierarchyRequestError do
  @moduledoc """
  Raised when a requested node insertion would create an invalid hierarchy.
  """

  defexception message: "The operation would yield an incorrect node tree."
end
