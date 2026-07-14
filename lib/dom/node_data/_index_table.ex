defmodule DOM.NodeData.IndexTable do
  @moduledoc """
  In-process operations over a document's `index` ETS table (an `:ordered_set`) — the
  derived-state store, separate from the `nodes` records table (`DOM.NodeData.NodesTable`).

  The index holds, keyed by a leading tag:
  - **span rows** `{{:span, root, key, kind, parent}, {node_id, type}}` — the nested-set
    adjacency mirror of the record extents, so a parent's ordered children (and a whole
    tree's extent) are contiguous ranges (O(log n + m) reads).
  - **membership rows** `{{:tag|:id|:class, value, ref} | {:attr, name, value, ref}, node_id}`
    — which nodes carry which tag/id/class/attribute, for selector matching.
  - **document / interaction singletons and queues**: range boundaries, listeners, the active
    event, microtasks, slot signals, mutation observers, timers, custom-element defs, the
    active element, `:target` fragment, hover/active pointer state, and traversal cursors.

  All functions here take an `index` tid and touch ONLY the index. Cross-table operations
  (create/relocate a node, which write both this table and the nodes records) live in
  `DOM.NodeData`.
  """

  use MatchSpec

  alias DOM.NodeData
  alias DOM.NodeData.Extent

  @type tid :: :ets.tid()
  @type id :: reference()

  # ==========================================================================
  # id/class index (a separate :ordered_set tid)
  # ==========================================================================
  #
  # Index rows are `{{:id | :class, value, make_ref()}, node_id}`. The trailing
  # ref makes each membership uniquely deletable; the ordered_set keeps rows that
  # share a `{:id, value, _}` prefix contiguous, so a lookup is a bounded prefix
  # range scan (O(log n + k)). The index tracks which node ROWS carry which
  # id/class — independent of tree reachability; scope filtering happens at query
  # time.

  @doc """
  Refresh `node_id`'s index rows from its `%NodeData.Element{}` record: retract its
  old rows, then insert one per membership — the tag (`local_name`), each id, and
  each (deduped) class token. Idempotent, so it covers set / change / remove
  uniformly.
  """
  @spec index_put(tid, id, NodeData.Element.t()) :: :ok
  def index_put(index, node_id, %NodeData.Element{} = element) do
    index_retract(index, node_id)

    for membership <- memberships(element) do
      # Each membership is `{kind, value…}`; the row key appends a fresh ref so
      # every membership is a distinct, individually-deletable ordered_set row.
      key = List.to_tuple(Tuple.to_list(membership) ++ [make_ref()])
      :ets.insert(index, {key, node_id})
    end

    :ok
  end

  @doc "Delete all index rows pointing at `node_id`."
  @spec index_retract(tid, id) :: :ok
  def index_retract(index, node_id) do
    for kind <- [:tag, :id, :class] do
      :ets.match_delete(index, {{kind, :_, :_}, node_id})
    end

    :ets.match_delete(index, {{:attr, :_, :_, :_}, node_id})
    :ok
  end

  @doc false
  # Every membership an element contributes to the index, each a tuple headed by
  # its kind (the index row key appends a fresh ref):
  #   {:tag, local_name} | {:id, value} | {:class, token} | {:attr, name, value}
  # Every attribute yields an {:attr, …} membership (id/class included), so their
  # attribute-selector forms are index-backed too, alongside the dedicated
  # {:id,…}/{:class,…} memberships. Single source of truth for index_put and the
  # consistency checker (in DOM.NodeData).
  def memberships(%NodeData.Element{local_name: local_name, attributes: attributes}) do
    # `id`/`class` are HTML (null-namespace) attributes — the bare-string-key patterns
    # match only plain attributes, so a namespaced `{_, "id", _}` triple correctly does
    # NOT populate getElementById / class matching.
    ids = for {"id", value} <- attributes, do: {:id, value}

    classes =
      for {"class", value} <- attributes, token <- class_tokens(value), do: {:class, token}

    # The :attr row keys on the attribute KEY verbatim (a plain string or a
    # {prefix, local, url} triple); the attribute match specs pin the key term.
    attrs = for {key, value} <- attributes, do: {:attr, key, value}
    [{:tag, local_name} | ids ++ classes ++ attrs]
  end

  # A class attribute's distinct whitespace-separated tokens (classList is a set,
  # so `class="x x"` yields one `x`). Mirrored in check_consistency!.
  defp class_tokens(value), do: value |> String.split() |> Enum.uniq()

  @doc "All node ids carrying `value` for the given index kind (`:tag`/`:id`/`:class`)."
  @spec index_lookup(tid, :tag | :id | :class, String.t()) :: [id]
  def index_lookup(index, :tag, value), do: :ets.select(index, index_tag_spec(value))
  def index_lookup(index, :id, value), do: :ets.select(index, index_id_spec(value))
  def index_lookup(index, :class, value), do: :ets.select(index, index_class_spec(value))

  defmatchspecp index_tag_spec(value) do
    {{:tag, ^value, _ref}, node_id} -> node_id
  end

  defmatchspecp index_id_spec(value) do
    {{:id, ^value, _ref}, node_id} -> node_id
  end

  defmatchspecp index_class_spec(value) do
    {{:class, ^value, _ref}, node_id} -> node_id
  end

  @doc """
  All node ids with attribute `name` == `value` — the exact-match path for
  `[name=value]` (a bounded prefix scan on the `{:attr, name, value, _}` prefix).
  """
  @spec index_lookup(tid, :attr, String.t(), String.t()) :: [id]
  def index_lookup(index, :attr, name, value) do
    :ets.select(index, index_attr_spec(name, value))
  end

  @doc """
  Every `{value, node_id}` for attribute `name` — the by-name path for `[name]`
  presence and the advanced operators (`~= |= ^= $= *=`) / `i` flag, which filter
  the values in the caller. A bounded prefix scan on the `{:attr, name, _, _}`
  prefix.
  """
  @spec index_lookup_attr_name(tid, String.t()) :: [{String.t(), id}]
  def index_lookup_attr_name(index, name) do
    :ets.select(index, index_attr_name_spec(name))
  end

  defmatchspecp index_attr_spec(name, value) do
    {{:attr, ^name, ^value, _ref}, node_id} -> node_id
  end

  defmatchspecp index_attr_name_spec(name) do
    {{:attr, ^name, value, _ref}, node_id} -> {value, node_id}
  end

  # ==========================================================================
  # Span rows (nested-set adjacency, in the index tid)
  # ==========================================================================
  #
  # Each node contributes two rows encoding its extent under its parent:
  #   {{:span, root, start, :start, parent}, node_id}
  #   {{:span, root, stop,  :stop,  parent}, node_id}
  # Keyed by `root` then the binary order-key, so one node's children — and one
  # tree's whole extent — are contiguous ranges in the ordered_set. Reading a
  # parent's ordered children is a bounded range scan (O(log n + m)).
  #
  # Dual-maintained with the `children` field during the adjacency migration; the
  # consistency checker asserts the two agree.

  @doc """
  Write the two span rows (`:start`/`:stop`) for `node_id`'s extent. The row VALUE is
  `{node_id, type}` — the node kind is carried in the span so element-only / type-filtered
  ordered reads (e.g. `children`) are a single range scan, no per-node record fetch.
  """
  @spec span_put(tid, id, %{
          root: id,
          parent: id | nil,
          start: Extent.t(),
          stop: Extent.t(),
          type: atom()
        }) ::
          :ok
  def span_put(index, node_id, %{root: root, parent: parent, start: start, stop: stop, type: type}) do
    :ets.insert(index, {{:span, root, start, :start, parent}, {node_id, type}})
    :ets.insert(index, {{:span, root, stop, :stop, parent}, {node_id, type}})
    :ok
  end

  @doc "Delete `node_id`'s span rows (matched by node id, so extent need not be known)."
  @spec span_retract(tid, id) :: :ok
  def span_retract(index, node_id) do
    :ets.match_delete(index, {{:span, :_, :_, :_, :_}, {node_id, :_}})
    :ok
  end

  @doc """
  The ordered child ids of `parent_id` within tree `root`, read from the span
  rows: the `:start` rows whose key falls strictly inside `(pstart, pstop)` and
  whose parent is `parent_id`, in `start` order. A bounded range scan.
  """
  @spec span_children(tid, id, id, Extent.t(), Extent.t()) :: [id]
  def span_children(index, root, parent_id, pstart, pstop) do
    :ets.select(index, span_children_spec(root, parent_id, pstart, pstop))
  end

  defmatchspecp span_children_spec(root, parent_id, pstart, pstop) do
    {{:span, ^root, s, :start, ^parent_id}, {node_id, _type}} when s > pstart and s < pstop ->
      node_id
  end

  @doc """
  The ELEMENT child ids of `parent_id` (extent `(pstart, pstop)`) within tree `root`, in
  document order — `span_children` plus a `type == :element` value guard, so it's the
  single ordered range scan that backs `ParentNode.children` (no per-node record fetch).
  """
  @spec span_element_children(tid, id, id, Extent.t(), Extent.t()) :: [id]
  def span_element_children(index, root, parent_id, pstart, pstop) do
    :ets.select(index, span_element_children_spec(root, parent_id, pstart, pstop))
  end

  defmatchspecp span_element_children_spec(root, parent_id, pstart, pstop) do
    {{:span, ^root, s, :start, ^parent_id}, {node_id, :element}} when s > pstart and s < pstop ->
      node_id
  end

  @doc false
  # Every span row as `{root, key, kind, parent, node_id, type}` — used by the consistency
  # checker (in DOM.NodeData).
  @spec span_rows(tid) :: [{id, Extent.t(), :start | :stop, id | nil, id, atom()}]
  def span_rows(index) do
    :ets.select(index, span_rows_spec())
  end

  defmatchspecp span_rows_spec() do
    {{:span, root, key, kind, parent}, {node_id, type}} ->
      {root, key, kind, parent, node_id, type}
  end

  @doc """
  The WHOLE span rows of the subtree occupying `(root, start..stop)` — every row whose
  order-key lies within the root's own window, inclusive of the endpoints. Returns the
  raw `{{:span, root, key, kind, parent}, {node_id, type}}` tuples so a relocation can
  transform and re-insert them. Bounded ordered-set range scan; backs `NodeData.rehome`.
  """
  @spec span_window(tid, id, Extent.t(), Extent.t()) :: [tuple()]
  def span_window(index, root, start, stop) do
    :ets.select(index, span_window_spec(root, start, stop))
  end

  @doc "Delete every span row in the `(root, start..stop)` window (same match as `span_window`)."
  @spec span_window_delete(tid, id, Extent.t(), Extent.t()) :: non_neg_integer()
  def span_window_delete(index, root, start, stop) do
    :ets.select_delete(index, span_window_delete_spec(root, start, stop))
  end

  defmatchspecp span_window_spec(root, start, stop) do
    {{:span, ^root, key, _kind, _parent}, _val} = row when key >= start and key <= stop ->
      row
  end

  defmatchspecp span_window_delete_spec(root, start, stop) do
    {{:span, ^root, key, _kind, _parent}, _val} when key >= start and key <= stop ->
      true
  end

  @doc false
  # Retract `id`'s old span rows and put fresh ones straight from its record extent. Used by
  # DOM.NodeData's span_index_all (the bulk mirror).
  def span_mirror_one(index, id, data) do
    span_retract(index, id)

    span_put(index, id, %{
      root: data.root,
      parent: data.parent,
      start: data.start,
      stop: data.stop,
      type: NodeData.type(data)
    })
  end

  # ==========================================================================
  # Range boundary rows (in the index tid) — PRIMARY state, not derived
  # ==========================================================================
  #
  # A Range's two boundaries are stored as:
  #   {{:range_start, extent_key, ref}, offset}
  #   {{:range_stop,  extent_key, ref}, offset}
  # where `extent_key` is the boundary CONTAINER node's own `start` key (so range
  # boundaries live in the same ordered coordinate space as node extents), `ref` is
  # the range identity (the owner's monitor ref — disambiguates same-position
  # boundaries and enables by-ref delete), and `offset` is the raw WHATWG offset
  # (child index for element/document/fragment, char index for text/comment).
  #
  # These rows are NOT derived from records; `span_index_all` and the span/index
  # checker passes leave them alone (check_index! already filters to tag/id/class/
  # attr; span checks read only `:span` rows).

  @doc "Write (replacing) a range's two boundary rows under `ref`."
  @spec range_put(
          tid,
          reference(),
          {Extent.t(), non_neg_integer()},
          {Extent.t(), non_neg_integer()}
        ) ::
          :ok
  def range_put(index, ref, {start_key, start_off}, {stop_key, stop_off}) do
    range_delete(index, ref)
    :ets.insert(index, {{:range_start, start_key, ref}, start_off})
    :ets.insert(index, {{:range_stop, stop_key, ref}, stop_off})
    :ok
  end

  @doc "Delete a range's boundary rows (matched by `ref`)."
  @spec range_delete(tid, reference()) :: :ok
  def range_delete(index, ref) do
    :ets.match_delete(index, {{:range_start, :_, ref}, :_})
    :ets.match_delete(index, {{:range_stop, :_, ref}, :_})
    :ok
  end

  @doc """
  A range's boundaries as `{{start_key, start_off}, {stop_key, stop_off}}`, or
  `nil` if the range is not present (detached / evicted).
  """
  @spec range_boundaries(tid, reference()) ::
          {{Extent.t(), non_neg_integer()}, {Extent.t(), non_neg_integer()}} | nil
  def range_boundaries(index, ref) do
    with [{start_key, start_off}] <- :ets.select(index, range_boundary_spec(:range_start, ref)),
         [{stop_key, stop_off}] <- :ets.select(index, range_boundary_spec(:range_stop, ref)) do
      {{start_key, start_off}, {stop_key, stop_off}}
    else
      _ -> nil
    end
  end

  defmatchspecp range_boundary_spec(kind, ref) do
    {{^kind, key, ^ref}, offset} -> {key, offset}
  end

  @doc "Whether a range `ref` currently has boundary rows in the index."
  @spec range_present?(tid, reference()) :: boolean()
  def range_present?(index, ref), do: range_boundaries(index, ref) != nil

  # ==========================================================================
  # Event listeners (:listener rows)
  # ==========================================================================
  #
  # A node's listeners are `{{:listener, node_id, seq}, %DOM.Listener{}}` rows.
  # `seq` is a per-node monotonic integer (next = current max + 1), so the
  # ordered_set iterates a node's listeners in registration order — the DOM's
  # listener fire order. The lambda lives in the value; never serialized/cloned.

  @doc "Append `listener` to `node_id`'s listeners (registration order preserved)."
  @spec listener_put(tid, id, DOM.Listener.t()) :: :ok
  def listener_put(index, node_id, %DOM.Listener{} = listener) do
    seq =
      case :ets.select(index, listener_seq_spec(node_id)) do
        [] -> 0
        seqs -> Enum.max(seqs) + 1
      end

    :ets.insert(index, {{:listener, node_id, seq}, listener})
    :ok
  end

  defmatchspecp listener_seq_spec(node_id) do
    {{:listener, ^node_id, seq}, _listener} -> seq
  end

  @doc "A node's listeners, in registration (fire) order."
  @spec listeners_of(tid, id) :: [DOM.Listener.t()]
  def listeners_of(index, node_id) do
    index
    |> :ets.select(listeners_of_spec(node_id))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defmatchspecp listeners_of_spec(node_id) do
    {{:listener, ^node_id, seq}, listener} -> {seq, listener}
  end

  @doc "Delete `node_id`'s listeners matching `(type, fn, capture)` (DOM identity)."
  @spec listener_delete(tid, id, String.t(), (... -> any()), boolean()) :: :ok
  def listener_delete(index, node_id, type, fun, capture) do
    for {key, %DOM.Listener{type: ^type, fn: ^fun, capture: ^capture}} <-
          :ets.select(index, listeners_row_spec(node_id)) do
      :ets.delete(index, key)
    end

    :ok
  end

  defmatchspecp listeners_row_spec(node_id) do
    {{:listener, ^node_id, seq}, listener} -> {{:listener, node_id, seq}, listener}
  end

  @doc "Drop all listener rows for `node_id` (node removed / adopted away)."
  @spec listeners_retract(tid, id) :: :ok
  def listeners_retract(index, node_id) do
    :ets.match_delete(index, {{:listener, node_id, :_}, :_})
    :ok
  end

  @doc """
  Delete every listener (on ANY node) registered with AbortSignal `signal_ref` — the
  `abort()` sweep for the `{signal}` addEventListener option.
  """
  @spec listeners_delete_by_signal(tid, reference()) :: :ok
  def listeners_delete_by_signal(index, signal_ref) do
    for key <- :ets.select(index, listeners_by_signal_spec(signal_ref)) do
      :ets.delete(index, key)
    end

    :ok
  end

  # The row KEYS of listeners registered with `signal_ref` (subset match on the struct's
  # signal_ref field — extra fields ignored).
  defmatchspecp listeners_by_signal_spec(signal_ref) do
    {{:listener, node_id, seq}, %{__struct__: DOM.Listener, signal_ref: ^signal_ref}} ->
      {:listener, node_id, seq}
  end

  # ==========================================================================
  # AbortSignal state ({:abort_signal, ref} rows)
  # ==========================================================================
  #
  # A signal's mutable state lives in one row keyed by its ref (shared with its
  # controller). `deps` holds the refs of composite signals (AbortSignal.any) that
  # must abort when this one does. AbortSignal/AbortController handles stay valid as
  # the row flips aborted — same server-backed-ref pattern as Range/TreeWalker.

  @doc "Create a fresh non-aborted AbortSignal state row under `ref`."
  @spec abort_signal_put(tid, reference()) :: :ok
  def abort_signal_put(index, ref) do
    :ets.insert(index, {{:abort_signal, ref}, %{aborted: false, reason: nil, deps: []}})
    :ok
  end

  @doc "An AbortSignal's state map (`%{aborted:, reason:, deps:}`), or `nil` if unknown."
  @spec abort_signal_get(tid, reference()) :: map() | nil
  def abort_signal_get(index, ref) do
    case :ets.lookup(index, {:abort_signal, ref}) do
      [{_key, state}] -> state
      [] -> nil
    end
  end

  @doc "Replace an AbortSignal's state map."
  @spec abort_signal_set(tid, reference(), map()) :: :ok
  def abort_signal_set(index, ref, state) do
    :ets.insert(index, {{:abort_signal, ref}, state})
    :ok
  end

  @doc "Register `dependent_ref` as a composite signal to notify when `ref` aborts."
  @spec abort_signal_add_dep(tid, reference(), reference()) :: :ok
  def abort_signal_add_dep(index, ref, dependent_ref) do
    if state = abort_signal_get(index, ref) do
      abort_signal_set(index, ref, %{state | deps: [dependent_ref | state.deps]})
    end

    :ok
  end

  # ==========================================================================
  # Active (in-flight) events (:active_event rows)
  # ==========================================================================
  #
  # Each in-flight dispatch owns one `{{:active_event, ref}, flags}` row holding the
  # event's mutable state (default_prevented / propagation_stopped /
  # immediate_stopped). Keyed by a per-dispatch ref so NESTED dispatches coexist
  # without clobbering — the ref also travels in the DOM.Event struct handed to
  # listeners, routing prevent_default/stop_* to the right row.

  @active_event_flags %{
    default_prevented: false,
    propagation_stopped: false,
    immediate_stopped: false
  }

  @doc "Open an active-event row for `ref` with all flags clear."
  @spec active_event_open(tid, reference()) :: :ok
  def active_event_open(index, ref) do
    :ets.insert(index, {{:active_event, ref}, @active_event_flags})
    :ok
  end

  @doc "Set one flag on the active-event row for `ref`."
  @spec active_event_set(tid, reference(), atom()) :: :ok
  def active_event_set(index, ref, flag) do
    [{key, flags}] = :ets.lookup(index, {:active_event, ref})
    :ets.insert(index, {key, Map.put(flags, flag, true)})
    :ok
  end

  @doc "The active-event flags map for `ref`."
  @spec active_event_flags(tid, reference()) :: %{atom() => boolean()}
  def active_event_flags(index, ref) do
    [{_key, flags}] = :ets.lookup(index, {:active_event, ref})
    flags
  end

  @doc "Delete the active-event row for `ref` (dispatch finished)."
  @spec active_event_close(tid, reference()) :: :ok
  def active_event_close(index, ref) do
    :ets.delete(index, {:active_event, ref})
    :ok
  end

  # ==========================================================================
  # Microtasks (:microtask rows)
  # ==========================================================================
  #
  # The document-global microtask queue: `{{:microtask, seq}, lambda}` rows, `seq`
  # a monotonic integer (next = max + 1). Because the index is an ordered_set, the
  # smallest seq is the oldest, so draining lowest-first is FIFO (enqueue order) —
  # the HTML microtask queue. A microtask is a ONE-SHOT deferred lambda (unlike a
  # :listener, which is durable and fires on every matching dispatch); it is run
  # once at the checkpoint and its row deleted. Not keyed by a node — microtasks
  # belong to the document, not a node.

  @doc "Enqueue `lambda` at the tail of the microtask queue."
  @spec microtask_enqueue(tid, (-> any())) :: :ok
  def microtask_enqueue(index, lambda) do
    seq =
      case :ets.select(index, microtask_seq_spec()) do
        [] -> 0
        seqs -> Enum.max(seqs) + 1
      end

    :ets.insert(index, {{:microtask, seq}, lambda})
    :ok
  end

  defmatchspecp microtask_seq_spec() do
    {{:microtask, seq}, _lambda} -> seq
  end

  @doc """
  Dequeue the oldest microtask (smallest seq): return `{seq, lambda}` and delete
  its row, or `:empty` when the queue is drained.
  """
  @spec microtask_take_oldest(tid) :: {non_neg_integer(), (-> any())} | :empty
  def microtask_take_oldest(index) do
    case :ets.select(index, microtask_rows_spec()) do
      [] ->
        :empty

      rows ->
        {seq, lambda} = Enum.min_by(rows, &elem(&1, 0))
        :ets.delete(index, {:microtask, seq})
        {seq, lambda}
    end
  end

  defmatchspecp microtask_rows_spec() do
    {{:microtask, seq}, lambda} -> {seq, lambda}
  end

  # "Signal a slot" dedup guard (:signaled_slot rows). A slot signaled for
  # slotchange within one task carries a `{{:signaled_slot, slot_id}, true}` row so a
  # second signal in the same task does not enqueue a second slotchange microtask;
  # the microtask deletes the row when it fires, so a change in a LATER task
  # re-signals. Transient (like :microtask) — never present outside a task.

  @doc "Mark `slot_id` signaled; returns true iff newly signaled (was not already)."
  @spec signal_slot(tid, id) :: boolean()
  def signal_slot(index, slot_id) do
    :ets.insert_new(index, {{:signaled_slot, slot_id}, true})
  end

  @doc "Clear `slot_id`'s signal (its slotchange microtask has fired)."
  @spec unsignal_slot(tid, id) :: :ok
  def unsignal_slot(index, slot_id) do
    :ets.delete(index, {:signaled_slot, slot_id})
    :ok
  end

  # ==========================================================================
  # MutationObserver registry + record queues
  # ==========================================================================
  #
  # Rows (all keyed by the observer ref):
  #   {{:observer, ref}, callback}              -- the registry (a 1-arg lambda)
  #   {{:observe, ref, target_id}, options}     -- one per observed target (opts map)
  #   {{:mo_record, ref, seq}, record}          -- queued MutationRecords, seq order
  # Records are one-shot (drained by the notify microtask or take_records) and the
  # observe/registry rows are explicit-lifetime (until disconnect) — like :listener,
  # they hold a lambda and are never mirror-checked, only asserted non-dangling.

  @doc "Register `callback` under `ref`."
  @spec observer_put(tid, reference(), (list() -> any())) :: :ok
  def observer_put(index, ref, callback) do
    :ets.insert(index, {{:observer, ref}, callback})
    :ok
  end

  @doc "The callback for `ref`, or nil if the observer was disconnected."
  @spec observer_callback(tid, reference()) :: (list() -> any()) | nil
  def observer_callback(index, ref) do
    case :ets.lookup(index, {:observer, ref}) do
      [{_key, callback}] -> callback
      [] -> nil
    end
  end

  @doc "Record that `ref` observes `target_id` with `options` (replacing any prior)."
  @spec observe_put(tid, reference(), id, map()) :: :ok
  def observe_put(index, ref, target_id, options) do
    :ets.insert(index, {{:observe, ref, target_id}, options})
    :ok
  end

  @doc "Every `{ref, target_id, options}` currently observed (across all observers)."
  @spec observations(tid) :: [{reference(), id, map()}]
  def observations(index) do
    for {{:observe, ref, target_id}, options} <- index_rows_of(index, :observe),
        do: {ref, target_id, options}
  end

  @doc "Append `record` to `ref`'s queue (mutation order)."
  @spec mo_record_put(tid, reference(), DOM.MutationRecord.t()) :: :ok
  def mo_record_put(index, ref, record) do
    seq =
      case :ets.select(index, mo_record_seq_spec(ref)) do
        [] -> 0
        seqs -> Enum.max(seqs) + 1
      end

    :ets.insert(index, {{:mo_record, ref, seq}, record})
    :ok
  end

  defmatchspecp mo_record_seq_spec(ref) do
    {{:mo_record, ^ref, seq}, _record} -> seq
  end

  @doc "Distinct observer refs that currently have queued records."
  @spec mo_record_refs(tid) :: [reference()]
  def mo_record_refs(index) do
    index
    |> :ets.select(mo_record_refs_spec())
    |> Enum.uniq()
  end

  defmatchspecp mo_record_refs_spec() do
    {{:mo_record, ref, _seq}, _record} -> ref
  end

  @doc "Return `ref`'s queued records in order (does not clear)."
  @spec mo_records(tid, reference()) :: [DOM.MutationRecord.t()]
  def mo_records(index, ref) do
    index
    |> :ets.select(mo_records_spec(ref))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defmatchspecp mo_records_spec(ref) do
    {{:mo_record, ^ref, seq}, record} -> {seq, record}
  end

  @doc "Return `ref`'s queued records in order AND delete them."
  @spec mo_take_records(tid, reference()) :: [DOM.MutationRecord.t()]
  def mo_take_records(index, ref) do
    records = mo_records(index, ref)
    :ets.match_delete(index, {{:mo_record, ref, :_}, :_})
    records
  end

  @doc "Disconnect `ref`: drop its registry, observe, and record rows."
  @spec observer_delete(tid, reference()) :: :ok
  def observer_delete(index, ref) do
    :ets.delete(index, {:observer, ref})
    :ets.match_delete(index, {{:observe, ref, :_}, :_})
    :ets.match_delete(index, {{:mo_record, ref, :_}, :_})
    :ok
  end

  # ==========================================================================
  # Timers (:timer rows)
  # ==========================================================================
  #
  # A pending timer: `{{:timer, ref}, {kind, callback, tref}}` where `kind` is
  # `:timeout` (one-shot) or `:interval` (repeating). `ref` is the id handed to the
  # caller (clear key); `tref` is the send_after/send_interval reference (cancellation).
  # The ROW is the source of truth for "should this timer run": a one-shot deletes its
  # row on fire, an interval keeps it; clearing deletes it. So a fired-then-cleared or a
  # message that outraces its cancel is a no-op. Unlike :microtask, a :timer row
  # legitimately persists across a consistency check (a scheduled timer lives in the
  # BEAM timer wheel; an interval persists by design).

  @doc "Store a pending timer: `ref` -> {kind, callback, send_after/interval tref}."
  @spec timer_put(tid, reference(), :timeout | :interval, (-> any()), reference()) :: :ok
  def timer_put(index, ref, kind, callback, tref) do
    :ets.insert(index, {{:timer, ref}, {kind, callback, tref}})
    :ok
  end

  @doc "The `{kind, callback, tref}` for `ref`, or nil if fired/cleared."
  @spec timer_get(tid, reference()) :: {:timeout | :interval, (-> any()), reference()} | nil
  def timer_get(index, ref) do
    case :ets.lookup(index, {:timer, ref}) do
      [{_key, value}] -> value
      [] -> nil
    end
  end

  @doc "Delete the timer row for `ref`."
  @spec timer_delete(tid, reference()) :: :ok
  def timer_delete(index, ref) do
    :ets.delete(index, {:timer, ref})
    :ok
  end

  # ==========================================================================
  # Custom-element registry (:custom_element_def rows)
  # ==========================================================================
  #
  # The document's customElements registry: `{{:custom_element_def, name}, def}` maps
  # a custom-element name to its DOM.CustomElementDefinition. Document-level singleton
  # state, stored as an index row like everything else. Definitions are permanent (a
  # name cannot be redefined) and never mirror-checked.

  @doc "Register `def` under custom-element `name` (caller enforces no-redefine)."
  @spec custom_element_put(tid, String.t(), DOM.CustomElementDefinition.t()) :: :ok
  def custom_element_put(index, name, def) do
    :ets.insert(index, {{:custom_element_def, name}, def})
    :ok
  end

  @doc "The definition for `name`, or nil if not defined."
  @spec custom_element_get(tid, String.t()) :: DOM.CustomElementDefinition.t() | nil
  def custom_element_get(index, name) do
    case :ets.lookup(index, {:custom_element_def, name}) do
      [{_key, def}] -> def
      [] -> nil
    end
  end

  # ==========================================================================
  # Focus (the :active_element singleton)
  # ==========================================================================
  #
  # The document's active (focused) element: a single `{:active_element}` row → the
  # focused node_id. Absent = nothing explicitly focused (reads fall back to <body> in
  # DOM). focus() sets it, blur() clears it.

  @doc "Set the active (focused) element to `node_id`."
  @spec active_element_put(tid, id) :: :ok
  def active_element_put(index, node_id) do
    :ets.insert(index, {:active_element, node_id})
    :ok
  end

  @doc "The active element's node_id, or nil if none is explicitly focused."
  @spec active_element_get(tid) :: id | nil
  def active_element_get(index) do
    case :ets.lookup(index, :active_element) do
      [{_key, node_id}] -> node_id
      [] -> nil
    end
  end

  @doc "Clear the active element (focus returns to the document body)."
  @spec active_element_clear(tid) :: :ok
  def active_element_clear(index) do
    :ets.delete(index, :active_element)
    :ok
  end

  # ==========================================================================
  # Document fragment (the :target singleton)
  # ==========================================================================
  #
  # The document's current URL fragment (the #foo part) as a `{:fragment}` row → string.
  # Dominique has no navigation, so DOM.set_fragment sets it; :target reads it. Absent =
  # no fragment (nothing is :target).

  @doc "Set the document fragment string (`nil` clears it)."
  @spec fragment_put(tid, String.t() | nil) :: :ok
  def fragment_put(index, nil), do: fragment_clear(index)

  def fragment_put(index, fragment) when is_binary(fragment) do
    :ets.insert(index, {:fragment, fragment})
    :ok
  end

  @doc "The document's current fragment string, or nil."
  @spec fragment_get(tid) :: String.t() | nil
  def fragment_get(index) do
    case :ets.lookup(index, :fragment) do
      [{_key, fragment}] -> fragment
      [] -> nil
    end
  end

  defp fragment_clear(index) do
    :ets.delete(index, :fragment)
    :ok
  end

  # ==========================================================================
  # Pointer state (the :hover / :active singletons)
  # ==========================================================================
  #
  # Pointer interaction state as `{:hover}` / `{:active}` rows → the target node_id.
  # No pointer input in Dominique, so DOM.set_hover/set_active set them; :hover/:active
  # read them (matching the target + its ancestors). `which` is :hover or :active.

  @doc "Set the `:hover`/`:active` target to `node_id`."
  @spec pointer_state_put(tid, :hover | :active, id) :: :ok
  def pointer_state_put(index, which, node_id) do
    :ets.insert(index, {which, node_id})
    :ok
  end

  @doc "The `:hover`/`:active` target node_id, or nil."
  @spec pointer_state_get(tid, :hover | :active) :: id | nil
  def pointer_state_get(index, which) do
    case :ets.lookup(index, which) do
      [{_key, node_id}] -> node_id
      [] -> nil
    end
  end

  @doc "Clear the `:hover`/`:active` target."
  @spec pointer_state_clear(tid, :hover | :active) :: :ok
  def pointer_state_clear(index, which) do
    :ets.delete(index, which)
    :ok
  end

  # ==========================================================================
  # Traversal objects (:traversal rows — TreeWalker / NodeIterator state)
  # ==========================================================================
  #
  # A TreeWalker or NodeIterator's mutable state as `{{:traversal, ref}, state_map}`.
  # Server-side (the handle is just server+ref), so the same handle stays valid as its
  # state advances. TreeWalker holds a `current`; NodeIterator holds `reference` +
  # `before?` (pointerBeforeReferenceNode), adjusted when a node is removed.

  @doc "Store the traversal state map for `ref`."
  @spec traversal_put(tid, reference(), map()) :: :ok
  def traversal_put(index, ref, state) do
    :ets.insert(index, {{:traversal, ref}, state})
    :ok
  end

  @doc "The traversal state map for `ref`, or nil."
  @spec traversal_get(tid, reference()) :: map() | nil
  def traversal_get(index, ref) do
    case :ets.lookup(index, {:traversal, ref}) do
      [{_key, state}] -> state
      [] -> nil
    end
  end

  @doc "Every NodeIterator `{ref, state}` (for removal adjustment)."
  @spec node_iterators(tid) :: [{reference(), map()}]
  def node_iterators(index) do
    for {{:traversal, ref}, %{kind: :node_iterator} = state} <- index_rows_of(index, :traversal),
        do: {ref, state}
  end

  @doc "Every range boundary row as `{kind, extent_key, ref, offset}`."
  @spec range_all_rows(tid) :: [
          {:range_start | :range_stop, Extent.t(), reference(), non_neg_integer()}
        ]
  def range_all_rows(index), do: :ets.select(index, range_rows_spec())

  defmatchspecp range_rows_spec() do
    {{kind, key, ref}, offset} when kind == :range_start or kind == :range_stop ->
      {kind, key, ref, offset}
  end

  @doc """
  Rewrite one range boundary row (identified by `kind`/`ref`) to a new
  `{extent_key, offset}` — the primitive live-range adjustment uses to remap a
  boundary onto a moved container's new key or a shifted offset.
  """
  @spec range_set_boundary(
          tid,
          :range_start | :range_stop,
          reference(),
          Extent.t(),
          non_neg_integer()
        ) ::
          :ok
  def range_set_boundary(index, kind, ref, extent_key, offset) do
    :ets.match_delete(index, {{kind, :_, ref}, :_})
    :ets.insert(index, {{kind, extent_key, ref}, offset})
    :ok
  end

  # All index rows of a given family, matched server-side by the key's head tag
  # (`elem(elem(entry, 0), 0) == kind`) — a whole-table copy is avoided regardless
  # of the family's key arity.
  defmatchspecp rows_of_kind(kind) do
    entry when elem(elem(entry, 0), 0) == kind -> entry
  end

  @doc "Every index row whose key is headed by `kind` (e.g. `:listener`, `:slot`)."
  @spec index_rows_of(tid, atom()) :: [{tuple(), term()}]
  def index_rows_of(index, kind), do: :ets.select(index, rows_of_kind(kind))
end
