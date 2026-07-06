defmodule DOM.NotFoundError do
  @moduledoc """
  Raised when a node required by an operation is not found where expected, such
  as a reference child that is not a child of the parent in `insert_before`.
  """

  defexception message: "The object can not be found here."
end
