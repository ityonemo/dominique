defmodule DOM.AbortError do
  @moduledoc """
  Raised by `DOM.AbortSignal.throw_if_aborted/1` when the signal is aborted. The
  raised value carries the signal's abort `reason` (an atom such as `:abort_error`
  or `:timeout_error`, or any user-supplied `abort/2` reason).
  """

  defexception message: "The operation was aborted.", reason: nil

  @impl true
  def exception(reason) do
    %__MODULE__{reason: reason, message: "The operation was aborted."}
  end
end
