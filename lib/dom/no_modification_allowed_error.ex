defmodule DOM.NoModificationAllowedError do
  @moduledoc """
  Raised when a modification is not allowed, such as setting `outerHTML` on an
  element that has no parent (there is nothing to replace it within).
  """

  defexception message: "The object can not be modified."
end
