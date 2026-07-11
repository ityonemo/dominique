defmodule DOM.NotSupportedError do
  @moduledoc """
  Raised when an operation is not supported — e.g. `Element.attachShadow` on an
  element that already has a shadow root or is not a valid shadow host.
  """

  defexception message: "The operation is not supported."
end
