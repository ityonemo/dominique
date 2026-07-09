defmodule DOM.Case do
  @moduledoc """
  `ExUnit.CaseTemplate` for tests that own a live document, arming the ETS
  consistency checker.

  Use `new_document/0,1` instead of `DOM.new/0,1`: it starts the document server
  UNLINKED (so it outlives the test process and is still alive in `on_exit`,
  unlike a linked or `start_supervised!` server, which is torn down first) and
  registers an `on_exit` hook that asserts `DOM.NodeData.Table.check_consistency!/2`
  then stops the server — every id-index and adjacency invariant holds at the end
  of the test. A violation fails the test that caused it, turning any missed
  index-maintenance path or dangling tree pointer into a loud, local failure.

      use DOM.Case

      test "…" do
        doc = new_document("<div id=x></div>")
        # … mutate …
      end                       # ← consistency asserted here, automatically
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import DOM.Case, only: [new_document: 0, new_document: 1]
    end
  end

  @doc """
  Start a supervised document (optionally parsing `html`) and register an
  `on_exit` consistency assertion. Returns the document handle.
  """
  @spec new_document(String.t() | nil) :: DOM.Node.t()
  def new_document(html \\ nil) do
    document_id = make_ref()

    opts =
      if html,
        do: [document_id: document_id, parse: DOM.HTML.tokens(html)],
        else: [document_id: document_id]

    # Unlinked: the server must survive the test process's exit so the on_exit
    # callback (which runs in a separate process afterward) can still reach its
    # live ETS tables. A linked or start_supervised! server is gone by then.
    {:ok, server} = GenServer.start(DOM, opts)
    ExUnit.Callbacks.on_exit(fn -> assert_consistent_and_stop(server) end)

    %DOM.Node{server: server, id: document_id, type: :document}
  end

  defp assert_consistent_and_stop(server) do
    :ok = DOM._check_index_consistency!(server)
  after
    if Process.alive?(server), do: GenServer.stop(server)
  end
end
