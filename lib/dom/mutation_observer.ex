defmodule DOM.MutationObserver do
  @moduledoc """
  Observe mutations to a node (and optionally its subtree) and receive batched
  `DOM.MutationRecord`s in a callback (WHATWG `MutationObserver`).

  The callback runs as a **microtask** — after the mutating task completes, once
  per observer, with all records queued during the task (see `DOM.MutationRecord`).
  It runs inside the document server (like an event listener) and receives the
  record list; it may itself mutate the tree.

      mo = DOM.MutationObserver.new(document, fn records -> ... end)
      DOM.MutationObserver.observe(mo, node, child_list: true, subtree: true)
      # ... mutations ...
      DOM.MutationObserver.disconnect(mo)

  A handle is `%DOM.MutationObserver{server, ref}`; `ref` keys the server-side
  registry row holding the callback. Observers are not auto-reclaimed — call
  `disconnect/1` (or let the document die).
  """

  alias DOM.Node

  @enforce_keys [:server, :ref]
  defstruct [:server, :ref]

  @type t :: %__MODULE__{server: GenServer.server(), ref: reference()}

  @typedoc """
  `observe/3` options: `child_list`, `attributes`, `character_data`, `subtree`,
  `attribute_old_value`, `character_data_old_value` (booleans), and
  `attribute_filter` (a list of attribute names to restrict `attributes` records).
  """
  @type option ::
          {:child_list, boolean()}
          | {:attributes, boolean()}
          | {:character_data, boolean()}
          | {:subtree, boolean()}
          | {:attribute_old_value, boolean()}
          | {:character_data_old_value, boolean()}
          | {:attribute_filter, [String.t()]}

  @doc "Create an observer whose `callback` receives a `[DOM.MutationRecord.t()]`."
  @spec new(Node.t(), ([DOM.MutationRecord.t()] -> any())) :: t()
  def new(%Node{type: :document, server: server}, callback) when is_function(callback, 1) do
    ref = DOM._mutation_observer_new(server, callback)
    %__MODULE__{server: server, ref: ref}
  end

  @doc "Begin observing `target` with `options` (see `t:option/0`)."
  @spec observe(t(), Node.t(), [option()]) :: :ok
  def observe(%__MODULE__{server: server, ref: ref}, %Node{node_id: target_id}, options \\ []) do
    DOM._mutation_observer_observe(server, ref, target_id, Map.new(options))
  end

  @doc "Stop observing all targets and clear this observer's pending records."
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{server: server, ref: ref}) do
    DOM._mutation_observer_disconnect(server, ref)
  end

  @doc "Return and clear this observer's queued records (suppresses the pending callback)."
  @spec take_records(t()) :: [DOM.MutationRecord.t()]
  def take_records(%__MODULE__{server: server, ref: ref}) do
    DOM._mutation_observer_take_records(server, ref)
  end
end
