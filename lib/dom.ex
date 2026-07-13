defmodule DOM do
  @moduledoc """
  A DOM document backed by a `GenServer` that owns a private ETS table of
  per-type `DOM.NodeData.*` records.

  Node handles are the single `DOM.Node` struct (`%DOM.Node{server, node_id, type}`),
  immutable references carrying the owning server, a node id, and the node kind;
  they are not live objects. Mutating operations run inside the server and may
  transfer whole subtrees between documents, after which a retained handle can
  become stale (see the README).

  Operations are partitioned by scope: **generic** node operations live on
  `DOM.Node`, **element-intrinsic** operations (`local_name`, the attribute API)
  on `DOM.Element`, and **whole-document / query** operations (creating nodes,
  `get_element_by_id/2`, `query_selector/2`, `matches/2`, …) here on `DOM`, which
  is also the GenServer holding every `*_impl`. Cross-module calls into the
  server go through the `_`-prefixed bridges in this module.
  """

  use GenServer
  use MatchSpec

  alias DOM.Event
  alias DOM.Events
  alias DOM.HTML.TreeBuilder
  alias DOM.MutationRecord
  alias DOM.Node
  alias DOM.NodeData
  alias DOM.NodeData.Slots
  alias DOM.NodeData.Table

  # ==========================================================================
  # Types
  # ==========================================================================

  @enforce_keys [:nodes, :index, :document_id]
  defstruct [:nodes, :index, :document_id, :fragment_root]

  @type state :: %__MODULE__{
          nodes: :ets.tid(),
          index: :ets.tid(),
          document_id: reference(),
          fragment_root: reference() | nil
        }

  @type t :: Node.t()

  # ==========================================================================
  # Lifecycle
  # ==========================================================================

  @doc """
  Start a document server. This is the primary entry point.

  Options: `:document_id` (required — the Document node's id); optional `:parse`
  (a decoded token list) or `:fragment` (`{tokens, context}`). When a build option
  is given, the tree is built into this server's own ETS table in a
  `handle_continue`, in-process, before the server serves any request.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    document_id = Keyword.fetch!(opts, :document_id)
    nodes = :ets.new(__MODULE__, [:set, :private])
    index = :ets.new(:"#{__MODULE__}.Index", [:ordered_set, :private])
    :ets.insert(nodes, {document_id, %NodeData.Document{}})
    # Stash the tids in the process dictionary so a re-entrant read from inside the
    # server (e.g. an event listener running during dispatch) can reach the tables
    # directly via NodeData._select_nodes/_select_index, without a deadlocking
    # GenServer.call back into this same process. See DOM.NodeData.
    Process.put(:nodes, nodes)
    Process.put(:index, index)
    Process.put(:document_id, document_id)
    state = %__MODULE__{nodes: nodes, index: index, document_id: document_id}

    case build_continue(opts) do
      nil -> {:ok, state}
      continue -> {:ok, state, {:continue, continue}}
    end
  end

  defp build_continue(opts) do
    cond do
      tokens = opts[:parse] -> {:parse, tokens}
      fragment = opts[:fragment] -> {:fragment, fragment}
      :else -> nil
    end
  end

  # ==========================================================================
  # API
  # ==========================================================================
  @type mutates() :: :mutates | nil

  @spec new(String.t() | nil) :: t()
  @spec create_element(t(), String.t()) :: Node.t()
  @spec create_text_node(t(), String.t()) :: Node.t()
  @spec create_comment(t(), String.t()) :: Node.t()
  @spec create_document_fragment(t()) :: Node.t()
  @spec create_document_type(t(), String.t(), String.t(), String.t()) :: Node.t()
  @spec get_elements_by_tag_name(Node.t(), String.t()) :: [Node.t()]
  @spec get_element_by_id(t(), String.t()) :: Node.t() | nil
  @spec get_elements_by_class_name(Node.t(), String.t()) :: [Node.t()]
  @spec query_selector(Node.t(), String.t()) :: Node.t() | nil
  @spec query_selector_all(Node.t(), String.t()) :: [Node.t()]
  @spec matches(Node.t(), String.t()) :: boolean()
  @spec _select_nodes(GenServer.server(), :ets.match_spec()) :: [term()]
  @spec _select_index(GenServer.server(), :ets.match_spec()) :: [term()]
  @spec _select_replace_nodes(GenServer.server(), :ets.match_spec()) :: non_neg_integer()
  @spec _select_replace_index(GenServer.server(), :ets.match_spec()) :: non_neg_integer()
  @spec _atomic_ets_op(GenServer.server(), (:ets.tid(), :ets.tid() -> result), mutates()) ::
          result
        when result: term()
  @spec _node_append_child(GenServer.server(), reference(), Node.t()) :: Node.t()
  @spec _node_insert_before(GenServer.server(), reference(), Node.t(), Node.t() | nil) :: Node.t()
  @spec _node_remove_child(GenServer.server(), reference(), Node.t()) :: Node.t()
  @spec _node_replace_child(GenServer.server(), reference(), Node.t(), Node.t()) :: Node.t()
  @spec _node_owner_document(GenServer.server(), reference()) :: Node.t() | nil
  @spec _node_clone_node(GenServer.server(), reference(), boolean()) :: Node.t()
  @spec _export_subtree(GenServer.server(), reference()) :: [{reference(), NodeData.t()}]
  @spec _remove_subtree(GenServer.server(), reference()) :: :ok
  @spec _element_inner_html(GenServer.server(), reference()) :: String.t()
  @spec _element_set_inner_html(GenServer.server(), reference(), String.t()) :: :ok
  @spec _element_set_outer_html(GenServer.server(), reference(), String.t()) :: :ok
  @spec _element_outer_html(GenServer.server(), reference()) :: String.t()
  @spec _node_text_content(GenServer.server(), reference()) :: String.t()
  @spec _node_set_text_content(GenServer.server(), reference(), String.t()) :: :ok
  @spec _node_set_value(GenServer.server(), reference(), String.t()) :: :ok

  # ==========================================================================
  # Implementations
  # ==========================================================================

  @doc """
  Convenience over `start_link/1`: create a document and return its handle. With
  no argument the document is empty; given an HTML string it is parsed (WHATWG
  tree construction) into the document's table before it is returned. Prefer
  `start_link/1` directly (e.g. under a supervisor); this wraps it and mints the
  `%DOM.Node{type: :document}` handle.
  """
  def new(html \\ nil)

  def new(nil), do: new_document(document_id: make_ref())

  def new(html) when is_binary(html),
    do: new_document(document_id: make_ref(), parse: DOM.HTML.tokens(html))

  defp new_document(opts) do
    {:ok, server} = start_link(opts)
    %Node{server: server, node_id: Keyword.fetch!(opts, :document_id), type: :document}
  end

  def create_element(document, local_name) do
    create(document, %NodeData.Element{local_name: local_name})
  end

  @doc """
  Creates an element in namespace `url` with qualified name `qualified_name`. `url`
  is one of the modeled namespace URLs (svg/mathml/html); the qualified name is
  stored as the element's `local_name`.
  """
  @spec create_element_ns(Node.t(), String.t(), String.t()) :: Node.t()
  def create_element_ns(%Node{type: :document} = document, url, qualified_name) do
    namespace = DOM.Namespace.element_atom(url) || :html
    create(document, %NodeData.Element{local_name: qualified_name, namespace: namespace})
  end

  @doc false
  # Internal: build an element with an explicit namespace and pre-adjusted
  # attribute list in one hop (used by the HTML tree builder for foreign
  # content). Attributes are stored verbatim — no name normalization.
  def _create_element_ns(document, local_name, namespace, attributes) do
    create(document, %NodeData.Element{
      local_name: local_name,
      namespace: namespace,
      attributes: attributes
    })
  end

  @doc false
  # Internal: the DocumentFragment holding a template element's contents.
  def _element_content(%Node{server: server, node_id: node_id}) do
    _atomic_ets_op(server, fn nodes, _index ->
      [{^node_id, %NodeData.Element{content: content_id}}] = :ets.lookup(nodes, node_id)
      if content_id, do: node_handle(nodes, content_id)
    end)
  end

  @doc false
  def _element_attach_shadow(server, node_id, mode, slot_assignment \\ :named) do
    result =
      _atomic_ets_op(
        server,
        fn nodes, index -> attach_shadow(nodes, index, node_id, mode, slot_assignment) end,
        :mutates
      )

    case result do
      {:ok, shadow} -> shadow
      {:error, :not_supported} -> raise DOM.NotSupportedError
    end
  end

  @doc false
  def _element_shadow_root(%Node{server: server, node_id: node_id}) do
    _atomic_ets_op(server, fn nodes, _index ->
      case Table.shadow_root(nodes, node_id) do
        nil -> nil
        shadow_id -> open_shadow_handle(nodes, shadow_id)
      end
    end)
  end

  def create_text_node(document, value), do: create(document, %NodeData.Text{value: value})

  def create_comment(document, value), do: create(document, %NodeData.Comment{value: value})

  def create_document_fragment(document), do: create(document, %NodeData.DocumentFragment{})

  def create_document_type(document, name, public_id, system_id) do
    node_data = %NodeData.DocumentType{name: name, public_id: public_id, system_id: system_id}
    create(document, node_data)
  end

  defp create(%Node{type: :document, server: server}, node_data) do
    _atomic_ets_op(server, fn nodes, index ->
      node_id = make_ref()
      Table.put(nodes, node_id, node_data)
      index_element(index, node_id, node_data)
      # custom element: run `constructed` if the created element's name is defined.
      if match?(%NodeData.Element{}, node_data) do
        custom_element_constructed(nodes, index, node_id, node_data.local_name)
      end

      node_handle(nodes, node_id)
    end)
  end

  defp create(%Node{}, _node_data), do: raise(DOM.HierarchyRequestError)

  def get_elements_by_tag_name(%Node{server: server, node_id: node_id}, name) do
    _atomic_ets_op(server, fn nodes, index ->
      get_elements_by_tag_name(nodes, index, node_id, name)
    end)
  end

  def get_element_by_id(%Node{server: server, node_id: root_id}, id) do
    _atomic_ets_op(server, fn nodes, index -> get_element_by_id(nodes, index, root_id, id) end)
  end

  def get_elements_by_class_name(%Node{server: server, node_id: root_id}, names) do
    _atomic_ets_op(server, fn nodes, index ->
      get_elements_by_class_name(nodes, index, root_id, names)
    end)
  end

  @doc "The document's root element (`<html>`), or `nil` for an empty document."
  @spec document_element(Node.t()) :: Node.t() | nil
  def document_element(%Node{type: :document} = document),
    do: document |> Node.children() |> List.first()

  @doc "The document's `<body>` element, or `nil`."
  @spec body(Node.t()) :: Node.t() | nil
  def body(%Node{type: :document} = document), do: query_selector(document, "body")

  @doc """
  The document's active (focused) element (HTML `document.activeElement`). Defaults to
  the `<body>` (or the document element) when nothing is explicitly focused.
  """
  @spec active_element(Node.t()) :: Node.t() | nil
  def active_element(%Node{type: :document, server: server} = document) do
    focused =
      _atomic_ets_op(server, fn nodes, index ->
        if id = Table.active_element_get(index), do: node_handle(nodes, id)
      end)

    focused || body(document) || document_element(document)
  end

  @doc """
  Set the document's URL fragment (the `#foo` part) — a convenience for `:target`,
  since Dominique models no navigation. `nil` (or the empty string) clears it. The
  `:target` pseudo-class then matches the element whose `id` equals `fragment` (or an
  `<a name=…>` when no id matches). Case-sensitive.
  """
  @spec set_fragment(Node.t(), String.t() | nil) :: :ok
  def set_fragment(%Node{type: :document, server: server}, fragment) do
    fragment = if fragment in [nil, ""], do: nil, else: fragment
    _atomic_ets_op(server, fn _nodes, index -> Table.fragment_put(index, fragment) end)
  end

  @doc """
  Set the `:hover` target to `element` — a convenience for `:hover`, since Dominique
  has no pointer input. `:hover` then matches `element` and all its ancestors (the
  "hover chain"). Clear with `clear_hover/1`.
  """
  @spec set_hover(Node.t()) :: :ok
  def set_hover(%Node{server: server, node_id: node_id}),
    do:
      _atomic_ets_op(server, fn _n, index -> Table.pointer_state_put(index, :hover, node_id) end)

  @doc "Clear the `:hover` target."
  @spec clear_hover(Node.t()) :: :ok
  def clear_hover(%Node{server: server}),
    do: _atomic_ets_op(server, fn _n, index -> Table.pointer_state_clear(index, :hover) end)

  @doc """
  Set the `:active` target to `element` (the pressed element) — a convenience for
  `:active`. Matches `element` and its ancestors. Clear with `clear_active/1`.
  """
  @spec set_active(Node.t()) :: :ok
  def set_active(%Node{server: server, node_id: node_id}),
    do:
      _atomic_ets_op(server, fn _n, index -> Table.pointer_state_put(index, :active, node_id) end)

  @doc "Clear the `:active` target."
  @spec clear_active(Node.t()) :: :ok
  def clear_active(%Node{server: server}),
    do: _atomic_ets_op(server, fn _n, index -> Table.pointer_state_clear(index, :active) end)

  @doc """
  Set the input's `indeterminate` property (the `:indeterminate` checkbox tri-state) —
  a convenience, since a browser sets it via the IDL property. Not an attribute; a click
  clears it.
  """
  @spec set_indeterminate(Node.t(), boolean()) :: :ok
  def set_indeterminate(%Node{server: server, node_id: node_id}, value) when is_boolean(value) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        record = fetch_node!(nodes, node_id)
        updated = %{record | indeterminate: value}
        :ets.insert(nodes, {node_id, updated})
        Table.index_put(index, node_id, updated)
        :ok
      end,
      :mutates
    )
  end

  @doc "The document's `<head>` element, or `nil`."
  @spec head(Node.t()) :: Node.t() | nil
  def head(%Node{type: :document} = document), do: query_selector(document, "head")

  @doc "Elements in `document` whose `name` attribute equals `name`, in tree order."
  @spec get_elements_by_name(Node.t(), String.t()) :: [Node.t()]
  def get_elements_by_name(%Node{type: :document} = document, name),
    do: query_selector_all(document, ~s([name="#{name}"]))

  @doc """
  Adopts `node` into `document`: removes it from its current tree and transfers
  ownership to `document`, returning the (possibly re-handled) detached node.
  """
  @spec adopt_node(Node.t(), Node.t()) :: Node.t()
  def adopt_node(%Node{type: :document} = document, %Node{} = node) do
    _adopt_node(document.server, node.server, node.node_id)
  end

  @doc """
  Imports a COPY of `node` (deep when `deep?`) into `document`, leaving the source
  untouched. Returns the detached copy owned by `document`.
  """
  @spec import_node(Node.t(), Node.t(), boolean()) :: Node.t()
  def import_node(%Node{type: :document} = document, %Node{} = node, deep? \\ false) do
    _import_node(document.server, node.server, node.node_id, deep?)
  end

  def query_selector(%Node{server: server, node_id: root_id}, selector) do
    selector = parse_selector!(selector)

    _atomic_ets_op(server, fn nodes, index ->
      case query_ids(root_id, selector, nodes, index) do
        [id | _] -> node_handle(nodes, id)
        [] -> nil
      end
    end)
  end

  def query_selector_all(%Node{server: server, node_id: root_id}, selector) do
    selector = parse_selector!(selector)

    _atomic_ets_op(server, fn nodes, index ->
      root_id |> query_ids(selector, nodes, index) |> Enum.map(&node_handle(nodes, &1))
    end)
  end

  def matches(%Node{server: server, node_id: node_id}, selector) do
    selector = parse_selector!(selector)
    _atomic_ets_op(server, fn nodes, index -> matches?(nodes, index, node_id, selector) end)
  end

  # Parse and validate a selector in the CALLER's process, so a malformed or
  # namespace-invalid selector raises `ArgumentError` here rather than crashing
  # the document server. The server receives the ready AST and never re-parses.
  defp parse_selector!(selector) do
    selector |> DOM.CSS.parse() |> DOM.CSS.validate!()
  end

  defp fragment_root_impl(_from, state) do
    {:reply, state.fragment_root, state}
  end

  # Build the parsed tree directly into this server's ETS table, in-process (via
  # DOM.NodeData.Table — no GenServer round-trips), before it serves any request.
  # handle_continue impls take no `from`.
  defp parse_impl(tokens, state) do
    TreeBuilder.build_into(state.nodes, state.index, state.document_id, tokens)
    Table.span_index_all(state.nodes, state.index)
    {:noreply, state}
  end

  defp fragment_impl(tokens, context, state) do
    root_id =
      TreeBuilder.build_fragment_into(
        state.nodes,
        state.index,
        state.document_id,
        tokens,
        context
      )

    Table.span_index_all(state.nodes, state.index)
    {:noreply, %{state | fragment_root: root_id}}
  end

  # Register an element's tag/id/class in the index (no-op for non-elements).
  defp index_element(index, node_id, %NodeData.Element{} = element) do
    Table.index_put(index, node_id, element)
  end

  defp index_element(_index, _node_id, _node_data), do: :ok

  # The content DocumentFragment handle of a template element (nil if unset).
  # Elements permitted to host a shadow root (§ "valid shadow host name"): a fixed
  # HTML set, plus any valid custom-element name (a hyphenated local name).
  @shadow_host_names ~w(article aside blockquote body div footer h1 h2 h3 h4 h5 h6
                        header main nav p section span)

  defp attach_shadow(nodes, index, id, mode, slot_assignment) do
    element = Table.fetch!(nodes, id)

    cond do
      element.shadow_root != nil ->
        {:error, :not_supported}

      not valid_shadow_host?(element.local_name) ->
        {:error, :not_supported}

      :else ->
        shadow_id = Table.create_shadow_root(nodes, id, mode, slot_assignment)
        Table.span_index_all(nodes, index)
        signal_slots(index, DOM.NodeData.Slots.recompute(nodes, index, id))
        {:ok, node_handle(nodes, shadow_id)}
    end
  end

  defp valid_shadow_host?(local_name) do
    local_name in @shadow_host_names or custom_element_name?(local_name)
  end

  # A valid custom element name contains a hyphen (a coarse but practical check).
  defp custom_element_name?(local_name), do: String.contains?(local_name, "-")

  defp open_shadow_handle(nodes, shadow_id) do
    if Table.shadow_mode(nodes, shadow_id) == :open, do: node_handle(nodes, shadow_id)
  end

  # Generic ETS primitives. A caller module (DOM.Node/DOM.Element) builds a match
  # spec with `defmatchspecp`/`fun2msfun` and drives a table directly through these,
  # instead of each row-local read/write needing its own bridge.
  #
  # Each forks on re-entrancy: called from OUTSIDE the server it does a
  # GenServer.call; called from INSIDE (server == self(), e.g. a listener running
  # during dispatch) it reads the tid from the process dictionary and runs in place
  # via the DOM.NodeData twins — a call back into the busy server would deadlock.
  def _select_nodes(server, match_spec) do
    if server == self(),
      do: NodeData._select_nodes(server, match_spec),
      else: GenServer.call(server, {:select_nodes, match_spec})
  end

  defp select_nodes_impl(match_spec, _from, state) do
    {:reply, :ets.select(state.nodes, match_spec), state}
  end

  def _select_index(server, match_spec) do
    if server == self(),
      do: NodeData._select_index(server, match_spec),
      else: GenServer.call(server, {:select_index, match_spec})
  end

  defp select_index_impl(match_spec, _from, state) do
    {:reply, :ets.select(state.index, match_spec), state}
  end

  def _select_replace_nodes(server, match_spec) do
    if server == self(),
      do: :ets.select_replace(Process.get(:nodes), match_spec),
      else: GenServer.call(server, {:select_replace_nodes, match_spec})
  end

  defp select_replace_nodes_impl(match_spec, _from, state) do
    {:reply, :ets.select_replace(state.nodes, match_spec), state}
  end

  def _select_replace_index(server, match_spec) do
    if server == self(),
      do: :ets.select_replace(Process.get(:index), match_spec),
      else: GenServer.call(server, {:select_replace_index, match_spec})
  end

  defp select_replace_index_impl(match_spec, _from, state) do
    {:reply, :ets.select_replace(state.index, match_spec), state}
  end

  # Runs a multi-step ETS operation `op.(nodes, index)` atomically inside the
  # server (a single message, so no other operation can interleave). Use this for
  # any read-modify-write against the tables that can't be a single `_select_*` /
  # `_select_replace_*` hit; `op` returns the value to reply with.
  #
  # Re-entrant fork (like _select_*): called from OUTSIDE the server it does a
  # GenServer.call; called from INSIDE (server == self(), e.g. an event listener
  # running during dispatch) it runs `op` directly against the pdict tids — a call
  # back into the busy server would deadlock. `op` is a pure function of the two
  # tids, so no server state is involved and the direct run is equivalent. This is
  # the deep seam: every read-modify-write built on _atomic_ets_op is re-entrant-
  # safe for free.
  #
  # Pass `:mutates` for a DOM MUTATION: after replying, the server runs a
  # microtask checkpoint ({:continue, :drain_microtasks}), where the microtasks a
  # mutation enqueues (slotchange, later MutationObserver) run. Only the OUTER
  # (GenServer.call) path acts on it; a re-entrant call (server == self(), nested in
  # a listener / running microtask / another mutation) NEVER drains regardless,
  # since microtasks run after the whole outer task, not mid-operation — the nested
  # frame only enqueues and inherits the outer frame's checkpoint. Reads omit it.
  def _atomic_ets_op(server, op, mutates \\ nil) do
    if server == self(),
      do: op.(Process.get(:nodes), Process.get(:index)),
      else: GenServer.call(server, {:atomic_ets_op, op, mutates})
  end

  defp atomic_ets_op_impl(op, mutates, _from, state) do
    result = op.(state.nodes, state.index)

    if mutates,
      do: {:reply, result, state, {:continue, :drain_microtasks}},
      else: {:reply, result, state}
  end

  @doc false
  # Enqueue a one-shot microtask `lambda` on the document-global queue. Dual, like
  # _atomic_ets_op: from OUTSIDE the server a GenServer.call whose handle_call
  # schedules a checkpoint (a {:continue, :drain_microtasks}) after replying; from
  # INSIDE (server == self(), e.g. a listener during dispatch, or a running
  # microtask) it enqueues ONLY — no checkpoint, because it is not a top-level task
  # but recursion under an outer frame that already owns the drain.
  def _enqueue_microtask(server, lambda) do
    if server == self(),
      do: Table.microtask_enqueue(Process.get(:index), lambda),
      else: GenServer.call(server, {:enqueue_microtask, lambda})
  end

  defp enqueue_microtask_impl(lambda, _from, state) do
    Table.microtask_enqueue(state.index, lambda)
    {:reply, :ok, state, {:continue, :drain_microtasks}}
  end

  # The microtask checkpoint: run the oldest microtask, then re-continue. Draining
  # one-per-continue keeps every lambda.() running under the SAME non-preemptible
  # continue chain — the runtime does not read the mailbox until the chain ends, so
  # a queued timer/UI task cannot jump ahead of the checkpoint (the HTML "perform a
  # microtask checkpoint" is uninterruptible), and microtasks enqueued mid-drain
  # (including a deferred dispatch_event) are picked up before it exits. An infinite
  # enqueue loop never returns to the mailbox — a faithful frozen tab.
  defp drain_microtasks_impl(state) do
    case Table.microtask_take_oldest(state.index) do
      :empty ->
        {:noreply, state}

      {_seq, lambda} ->
        lambda.()
        {:noreply, state, {:continue, :drain_microtasks}}
    end
  end

  # ==========================================================================
  # Custom elements (reactions run SYNCHRONOUSLY with their trigger)
  # ==========================================================================
  #
  # A definition is a DOM.CustomElementDefinition (callbacks + observed_attributes)
  # stored per document under {:custom_element_def, name}. Unlike slotchange /
  # MutationObserver, custom-element reactions are NOT microtask-deferred — the
  # browser runs connectedCallback DURING appendChild, etc. So we invoke the callbacks
  # INLINE at the end of each triggering op (create / setAttribute / append / remove /
  # define-upgrade). An element carries a {:upgraded, node_id} guard so `constructed`
  # runs exactly once. See the custom-element-semantics memory.

  @doc """
  Define a custom element `name` (which must contain a hyphen) with `definition`, then
  upgrade any already-existing elements of that name. Raises `DOM.NotSupportedError` if
  `name` is already defined, `ArgumentError` if `name` is not a valid custom-element
  name. This is the HTML `customElements.define`.
  """
  @spec define_element(Node.t(), String.t(), DOM.CustomElementDefinition.t()) :: :ok
  def define_element(%Node{server: server}, name, %DOM.CustomElementDefinition{} = definition) do
    unless custom_element_name?(name) do
      raise ArgumentError, "#{inspect(name)} is not a valid custom element name (needs a hyphen)"
    end

    result =
      _atomic_ets_op(
        server,
        fn nodes, index ->
          if Table.custom_element_get(index, name) do
            {:error, :already_defined}
          else
            Table.custom_element_put(index, name, definition)
            upgrade_all(nodes, index, name, definition)
            :ok
          end
        end,
        :mutates
      )

    case result do
      :ok -> :ok
      {:error, :already_defined} -> raise DOM.NotSupportedError, "#{name} is already defined"
    end
  end

  @doc "The definition registered for custom-element `name`, or nil. HTML `customElements.get`."
  @spec custom_element_get(Node.t(), String.t()) :: DOM.CustomElementDefinition.t() | nil
  def custom_element_get(%Node{server: server}, name) do
    _atomic_ets_op(server, fn _nodes, index -> Table.custom_element_get(index, name) end)
  end

  # Upgrade every UNDEFINED element of `name` in document order (an already-upgraded
  # element — one that carries a definition — is left alone): constructed →
  # attributeChanged for each existing observed attribute → connected (if connected).
  defp upgrade_all(nodes, index, name, definition) do
    for node_id <- elements_named(nodes, name),
        fetch_node!(nodes, node_id).definition == nil do
      upgrade(nodes, index, node_id, definition)
    end
  end

  # Elements whose local_name is `name`, in document order.
  defp elements_named(nodes, name) do
    Table.elements_by_tag_name(nodes, Process.get(:document_id), name)
  end

  # Attach `definition` to the element (the upgrade marker), then run constructed,
  # attributeChanged for each existing observed attr, and connected (if in a tree).
  defp upgrade(nodes, index, node_id, definition) do
    set_definition(nodes, index, node_id, definition)
    run_callback(definition.constructed, node_handle(nodes, node_id))

    for {name, value} <- observed_attributes_present(nodes, node_id, definition) do
      run_callback4(definition.attribute_changed, node_handle(nodes, node_id), name, nil, value)
    end

    if connected?(nodes, node_id) do
      run_callback(definition.connected, node_handle(nodes, node_id))
    end
  end

  # Store `definition` on the element record (the persistent upgrade marker).
  defp set_definition(nodes, index, node_id, definition) do
    record = fetch_node!(nodes, node_id)
    updated = %{record | definition: definition}
    :ets.insert(nodes, {node_id, updated})
    Table.index_put(index, node_id, updated)
    :ok
  end

  # An element's own definition (nil if undefined/not a custom element).
  defp definition_of(nodes, node_id), do: fetch_node!(nodes, node_id).definition

  # The element's string-keyed attributes that the definition observes, in order.
  defp observed_attributes_present(nodes, node_id, definition) do
    observed = definition.observed_attributes

    for {key, value} <- fetch_node!(nodes, node_id).attributes,
        is_binary(key),
        key in observed,
        do: {key, value}
  end

  # The reaction hooks called from the mutation ops (all synchronous, no microtask).

  # constructed: at create_element, if `local_name` is a defined custom element. The
  # definition is attached to the element (its upgrade marker) before the callback.
  defp custom_element_constructed(nodes, index, node_id, local_name) do
    if definition = Table.custom_element_get(index, local_name) do
      set_definition(nodes, index, node_id, definition)
      run_callback(definition.constructed, node_handle(nodes, node_id))
    end

    :ok
  end

  # connected: for each upgraded custom element in the inserted subtree, tree order.
  defp custom_element_connected(nodes, root_id) do
    for {node_id, definition} <- upgraded_in_subtree(nodes, root_id) do
      run_callback(definition.connected, node_handle(nodes, node_id))
    end

    :ok
  end

  # The {node_id, definition} of every upgraded custom element in the subtree being
  # removed — captured BEFORE detaching, and only when the parent is connected (a
  # remove from a detached subtree fires no disconnectedCallback). [] otherwise.
  defp capture_disconnecting(nodes, parent_id, child_id) do
    if connected?(nodes, parent_id), do: upgraded_in_subtree(nodes, child_id), else: []
  end

  # Like capture_disconnecting, but keyed on the ADOPTED root itself being connected
  # (adopt detaches the root, so the root's own connectedness decides disconnect).
  defp capture_disconnecting_root(nodes, root_id) do
    if connected?(nodes, root_id), do: upgraded_in_subtree(nodes, root_id), else: []
  end

  # adopted: in the destination, for each upgraded custom element in the adopted
  # subtree (the definition rode in on the element), fire adoptedCallback(element,
  # old_document, new_document).
  defp custom_element_adopted(nodes, root_id, old_doc) do
    new_doc = document_handle(nodes, Process.get(:document_id))

    for {node_id, definition} <- upgraded_in_subtree(nodes, root_id) do
      run_adopted(definition.adopted, node_handle(nodes, node_id), old_doc, new_doc)
    end

    :ok
  end

  defp document_handle(_nodes, document_id) do
    %Node{server: self(), node_id: document_id, type: :document}
  end

  defp run_adopted(nil, _el, _old, _new), do: :ok
  defp run_adopted(fun, el, old, new) when is_function(fun, 3), do: fun.(el, old, new)

  # disconnected: run for each pre-captured {node_id, definition} of the removed
  # subtree (captured before detaching, since after removal they are no longer found).
  defp custom_element_disconnected(nodes, removed) do
    for {node_id, definition} <- removed do
      run_callback(definition.disconnected, node_handle(nodes, node_id))
    end

    :ok
  end

  @doc false
  # attributeChanged: fires for an UPGRADED element on EVERY set of an observed attr
  # (even to the same value — unlike MutationObserver). Reads the element's carried
  # definition. @doc false so DOM.Element's attribute path can reach it across the
  # module boundary. (`_index` kept for a uniform bridge signature.)
  def _custom_element_attribute_changed(nodes, _index, node_id, name, old, new) do
    definition = definition_of(nodes, node_id)

    if definition && name in definition.observed_attributes do
      run_callback4(definition.attribute_changed, node_handle(nodes, node_id), name, old, new)
    end

    :ok
  end

  # The {id, definition} of every UPGRADED custom element in `root_id`'s subtree (root
  # inclusive), document order — those carrying a definition on their record.
  defp upgraded_in_subtree(nodes, root_id) do
    for {id, %NodeData.Element{definition: def}} when def != nil <- subtree(nodes, root_id),
        do: {id, def}
  end

  # Connected = the node's tree root is the document. `root` is the nested-set anchor
  # maintained on every append/insert/graft, so this is an O(1) field read (no walk).
  defp connected?(nodes, node_id),
    do: fetch_node!(nodes, node_id).root == Process.get(:document_id)

  defp run_callback(nil, _el), do: :ok
  defp run_callback(fun, el) when is_function(fun, 1), do: fun.(el)

  defp run_callback4(nil, _el, _name, _old, _new), do: :ok

  defp run_callback4(fun, el, name, old, new) when is_function(fun, 4),
    do: fun.(el, name, old, new)

  # ==========================================================================
  # Focus (the document's active element)
  # ==========================================================================
  #
  # A document-level active-element singleton (HTML focus management, not DOM proper).
  # focus() sets it when the target is focusable AND connected; blur() clears it (focus
  # falls back to <body> in active_element/1). A focus MOVE fires the focus-event
  # sequence (blur/focusout on the old, focus/focusin on the new).

  @doc false
  def _node_focus(server, node_id) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        previous = Table.active_element_get(index)

        if focusable?(nodes, node_id) and connected?(nodes, node_id) and previous != node_id do
          Table.active_element_put(index, node_id)
          fire_focus_change(nodes, index, previous, node_id)
        end

        :ok
      end,
      :mutates
    )
  end

  @doc false
  def _node_blur(server, node_id) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        # blur only clears focus if THIS element is the active one (matches the browser:
        # blurring a non-focused element is a no-op).
        if Table.active_element_get(index) == node_id do
          Table.active_element_clear(index)
          fire_focus_change(nodes, index, node_id, nil)
        end

        :ok
      end,
      :mutates
    )
  end

  # Dispatch the focus-move event sequence: the blur pair on `old` (relatedTarget =
  # `new`) BEFORE the focus pair on `new` (relatedTarget = `old`). focus/blur are
  # non-bubbling, focusin/focusout bubble; all composed, none cancelable. `old`/`new`
  # may be nil (initial focus / blur to nothing). Runs in-server (server == self()).
  defp fire_focus_change(nodes, index, old, new) do
    if old, do: fire_focus_pair(nodes, index, old, "blur", "focusout", new)
    if new, do: fire_focus_pair(nodes, index, new, "focus", "focusin", old)
    :ok
  end

  defp fire_focus_pair(nodes, index, target_id, direct, bubbling, related_id) do
    related = related_id && node_handle(nodes, related_id)
    dispatch_focus(nodes, index, target_id, direct, related, false)
    dispatch_focus(nodes, index, target_id, bubbling, related, true)
  end

  defp dispatch_focus(nodes, index, target_id, type, related, bubbles?) do
    event = Event.new(type, bubbles: bubbles?, composed: true, related_target: related)
    Events.dispatch(nodes, index, self(), target_id, event)
    :ok
  end

  # Whether `node_id` is a focusable element: a[href]/button/select/textarea, input
  # (except type=hidden), or any element carrying a `tabindex` — none of them disabled.
  # Pure predicate over name + attributes (reusable for sequential focus later).
  defp focusable?(nodes, node_id) do
    case fetch_node!(nodes, node_id) do
      %NodeData.Element{} = el -> focusable_element?(el)
      _ -> false
    end
  end

  defp focusable_element?(%NodeData.Element{} = el) do
    not disabled?(el) and (has_tabindex?(el) or focusable_by_kind?(el))
  end

  defp focusable_by_kind?(%NodeData.Element{local_name: name} = el) do
    case name do
      "a" -> has_string_attr?(el, "href")
      "area" -> has_string_attr?(el, "href")
      "input" -> get_string_attr(el, "type") != "hidden"
      n when n in ~w(button select textarea) -> true
      _ -> false
    end
  end

  defp disabled?(el), do: has_string_attr?(el, "disabled")
  defp has_tabindex?(el), do: has_string_attr?(el, "tabindex")

  defp has_string_attr?(%NodeData.Element{attributes: attrs}, name),
    do: Enum.any?(attrs, fn {k, _v} -> k == name end)

  defp get_string_attr(%NodeData.Element{attributes: attrs}, name) do
    case Enum.find(attrs, fn {k, _v} -> k == name end) do
      {_k, v} -> v
      nil -> nil
    end
  end

  # ==========================================================================
  # Timers + queueMicrotask (HTML WindowOrWorkerGlobalScope)
  # ==========================================================================
  #
  # NOTE: setTimeout/clearTimeout/queueMicrotask are HTML-spec methods on
  # WindowOrWorkerGlobalScope (mixed into Window), NOT part of the DOM proper.
  # Dominique has no Window; they are provided here on the DOM context module as a
  # convenience, because the document server already owns the event loop they drive.

  @doc """
  Run `callback` (a 0-arity function) as a TASK after `delay` ms — the HTML
  `setTimeout`. Returns an opaque id for `clear_timeout/2`. The callback runs inside
  the document server (like an event listener), followed by a microtask checkpoint,
  so microtasks it enqueues drain before the next task. A convenience method (see the
  section note); `delay` defaults to 0.
  """
  @spec set_timeout(Node.t(), (-> any()), non_neg_integer()) :: reference()
  def set_timeout(%Node{server: server}, callback, delay \\ 0) when is_function(callback, 0) do
    if server == self() do
      schedule_timer(server, :timeout, callback, delay)
    else
      GenServer.call(server, {:set_timer, :timeout, callback, delay})
    end
  end

  @doc """
  Run `callback` every `delay` ms as a repeating TASK — the HTML `setInterval`. Like
  `set_timeout/3` but the timer re-fires until `clear_interval/2`. Returns an id for
  `clear_interval/2`. A convenience method (see the section note).
  """
  @spec set_interval(Node.t(), (-> any()), non_neg_integer()) :: reference()
  def set_interval(%Node{server: server}, callback, delay) when is_function(callback, 0) do
    if server == self() do
      schedule_timer(server, :interval, callback, delay)
    else
      GenServer.call(server, {:set_timer, :interval, callback, delay})
    end
  end

  # Schedule a timer (targeting the server) and record the {:timer, ref} row. A
  # :timeout uses Process.send_after (one message); an :interval uses
  # :timer.send_interval (a repeating message) whose tref :timer.cancel stops. Runs in
  # the server (self() == server), from the handle_call or re-entrantly.
  defp schedule_timer(server, kind, callback, delay) do
    ref = make_ref()

    tref =
      case kind do
        :timeout ->
          Process.send_after(server, {:run_timer, ref}, delay)

        :interval ->
          {:ok, tref} = :timer.send_interval(delay, server, {:run_timer, ref})
          tref
      end

    Table.timer_put(Process.get(:index), ref, kind, callback, tref)
    ref
  end

  defp set_timer_impl(kind, callback, delay, _from, state) do
    {:reply, schedule_timer(self(), kind, callback, delay), state}
  end

  @doc "Cancel a pending `set_timeout/3` timer by its id (a no-op if already fired)."
  @spec clear_timeout(Node.t(), reference()) :: :ok
  def clear_timeout(%Node{} = document, id), do: cancel_timer(document, id)

  @doc "Cancel a repeating `set_interval/3` timer by its id (a no-op if already cleared)."
  @spec clear_interval(Node.t(), reference()) :: :ok
  def clear_interval(%Node{} = document, id), do: cancel_timer(document, id)

  defp cancel_timer(%Node{server: server}, id) do
    _atomic_ets_op(server, fn _nodes, index ->
      if timer = Table.timer_get(index, id) do
        {kind, _callback, tref} = timer
        cancel_tref(kind, tref)
        Table.timer_delete(index, id)
      end

      :ok
    end)
  end

  defp cancel_tref(:timeout, tref), do: Process.cancel_timer(tref)
  defp cancel_tref(:interval, tref), do: :timer.cancel(tref)

  # Fire a timer: if its row is still present (not cleared), run the callback. A
  # one-shot (:timeout) deletes its row; an :interval keeps it (it re-fires). Then run
  # a microtask checkpoint (the timer's trailing checkpoint — a microtask it enqueued
  # drains before the next task, since handle_continue runs before the mailbox is read).
  defp run_timer_impl(ref, state) do
    case Table.timer_get(state.index, ref) do
      nil ->
        {:noreply, state}

      {:timeout, callback, _tref} ->
        Table.timer_delete(state.index, ref)
        callback.()
        {:noreply, state, {:continue, :drain_microtasks}}

      {:interval, callback, _tref} ->
        callback.()
        {:noreply, state, {:continue, :drain_microtasks}}
    end
  end

  @doc """
  Enqueue `callback` (0-arity) as a microtask — the HTML `queueMicrotask`. Runs at
  the next microtask checkpoint (before the next task), inside the document server.
  A convenience method (see the section note).
  """
  @spec queue_microtask(Node.t(), (-> any())) :: :ok
  def queue_microtask(%Node{server: server}, callback) when is_function(callback, 0) do
    _enqueue_microtask(server, callback)
  end

  # ==========================================================================
  # MutationObserver
  # ==========================================================================

  @doc false
  def _mutation_observer_new(server, callback) do
    ref = make_ref()
    _atomic_ets_op(server, fn _nodes, index -> Table.observer_put(index, ref, callback) end)
    ref
  end

  @doc false
  def _mutation_observer_observe(server, ref, target_id, options) do
    _atomic_ets_op(server, fn _nodes, index ->
      Table.observe_put(index, ref, target_id, options)
    end)
  end

  @doc false
  def _mutation_observer_disconnect(server, ref) do
    _atomic_ets_op(server, fn _nodes, index -> Table.observer_delete(index, ref) end)
  end

  @doc false
  def _mutation_observer_take_records(server, ref) do
    _atomic_ets_op(server, fn _nodes, index -> Table.mo_take_records(index, ref) end)
  end

  @doc false
  # Private, for testing purposes: run an arbitrary 0-arity `fun` INSIDE the
  # document server process, so a test can exercise a DOM operation under the exact
  # condition an event listener runs under (server == self()). Its return value is
  # replied back. If `fun` calls a DOM operation that is not re-entrant-safe, this
  # deadlocks (the test times out) — which is precisely what such a test asserts
  # against.
  def lambda(server, fun) do
    GenServer.call(server, {:lambda, fun})
  end

  defp lambda_impl(fun, _from, state) do
    # DOM.lambda runs arbitrary code inside the server — it is a top-level task, so
    # it ends with a microtask checkpoint (a listener/op run under it may enqueue).
    {:reply, fun.(), state, {:continue, :drain_microtasks}}
  end

  # ==========================================================================
  # Ranges
  # ==========================================================================

  @doc false
  # Create a range collapsed at (document, 0); monitor `owner` for cleanup. The
  # returned ref (the monitor ref) is the range's identity. Owner == this server
  # is illegal (a range must be owned by an external process).
  def _range_create(server, document_id, owner) do
    GenServer.call(server, {:range_create, document_id, owner})
  end

  defp range_create_impl(document_id, owner, _from, state) do
    if owner == self() do
      raise ArgumentError, "a range may not be owned by the document server process"
    end

    ref = Process.monitor(owner)
    key = Table.fetch!(state.nodes, document_id).start
    Table.range_put(state.index, ref, {key, 0}, {key, 0})
    {:reply, ref, state}
  end

  @doc false
  def _range_detach(server, range_id) do
    GenServer.call(server, {:range_detach, range_id})
  end

  defp range_detach_impl(range_id, _from, state) do
    Process.demonitor(range_id, [:flush])
    Table.range_delete(state.index, range_id)
    {:reply, :ok, state}
  end

  # An owner process died: drop all of its ranges (the :DOWN ref IS the range id).
  defp range_cleanup_impl(range_id, state) do
    Table.range_delete(state.index, range_id)
    {:noreply, state}
  end

  @doc false
  # splitText (§): the original keeps chars 0..offset, a new Text sibling gets the
  # remainder. Boundaries in the original past `offset` move into the new node.
  def _text_split(server, node_id, offset) do
    result =
      _atomic_ets_op(
        server,
        fn nodes, index -> text_split_op(nodes, index, node_id, offset) end,
        :mutates
      )

    case result do
      {:ok, new_node} -> new_node
      {:error, :index_size} -> raise DOM.IndexSizeError
    end
  end

  defp text_split_op(nodes, index, node_id, offset) do
    value = Table.value(nodes, node_id)

    if offset > String.length(value) do
      {:error, :index_size}
    else
      {before, rest} = String.split_at(value, offset)
      orig_key = Table.fetch!(nodes, node_id).start
      parent_id = Table.parent(nodes, node_id)

      snapshot = range_snapshot(nodes, index)
      Table.set_value(nodes, node_id, before)
      new_id = Table.create_text(nodes, rest)
      insert_after(nodes, parent_id, new_id, node_id)
      resync_spans(nodes, index)

      new_key = Table.fetch!(nodes, new_id).start
      adjust_split_ranges(nodes, index, snapshot, parent_id, node_id, orig_key, new_key, offset)

      {:ok, node_handle(nodes, new_id)}
    end
  end

  @doc false
  def _range_clone_contents(server, range_id) do
    _atomic_ets_op(server, fn nodes, index ->
      {sc, so, ec, eo} = range_endpoints!(nodes, index, range_id)
      clones = DOM.Range.Contents.clone(nodes, sc, so, ec, eo)

      fragment_id = make_ref()
      Table.put(nodes, fragment_id, %NodeData.DocumentFragment{})
      Table.append_children(nodes, fragment_id, clones)
      Table.reindex(nodes, index)
      resync_spans(nodes, index)

      node_handle(nodes, fragment_id)
    end)
  end

  @doc false
  def _range_extract_contents(server, range_id) do
    _atomic_ets_op(
      server,
      fn nodes, index -> range_extract_op(nodes, index, range_id) end,
      :mutates
    )
  end

  defp range_extract_op(nodes, index, range_id) do
    {sc, so, ec, eo} = range_endpoints!(nodes, index, range_id)
    snapshot = range_snapshot(nodes, index)
    extracted = DOM.Range.Contents.extract(nodes, sc, so, ec, eo)

    fragment_id = make_ref()
    Table.put(nodes, fragment_id, %NodeData.DocumentFragment{})
    Table.append_children(nodes, fragment_id, extracted)
    Table.reindex(nodes, index)
    resync_spans(nodes, index)

    collapse_range_to_start(index, range_id)
    reconcile_ranges(nodes, index, snapshot)

    node_handle(nodes, fragment_id)
  end

  @doc false
  def _range_delete_contents(server, range_id) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        {sc, so, ec, eo} = range_endpoints!(nodes, index, range_id)
        snapshot = range_snapshot(nodes, index)
        extracted = DOM.Range.Contents.extract(nodes, sc, so, ec, eo)

        Enum.each(extracted, &delete_subtree(nodes, index, &1))
        resync_spans(nodes, index)

        collapse_range_to_start(index, range_id)
        reconcile_ranges(nodes, index, snapshot)

        :ok
      end,
      :mutates
    )
  end

  @doc false
  def _range_insert_node(server, range_id, node_id) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        {{start_key, so}, _stop} = Table.range_boundaries(index, range_id)
        container = Table.node_at_start_key(nodes, start_key)
        do_insert_at_boundary(nodes, index, container, so, node_id)
        :ok
      end,
      :mutates
    )
  end

  # Insert node_id at boundary (container, offset). Text container: split at offset
  # (unless at an edge) and insert before the tail. Element/fragment: insert at the
  # child index `offset`.
  defp do_insert_at_boundary(nodes, index, container, offset, node_id) do
    if Table.type(nodes, container) in [:text, :comment] do
      insert_into_text(nodes, index, container, offset, node_id)
    else
      insert_at_child_index(nodes, index, container, offset, node_id)
    end
  end

  defp insert_into_text(nodes, index, text_id, offset, node_id) do
    parent_id = Table.parent(nodes, text_id)

    reference =
      cond do
        offset == 0 -> text_id
        offset >= String.length(Table.value(nodes, text_id)) -> nil
        :else -> split_text_for_insert(nodes, text_id, offset)
      end

    insert_relative(nodes, index, parent_id, node_id, reference)
  end

  # Split `text_id` at `offset`; return the tail node to insert before.
  defp split_text_for_insert(nodes, text_id, offset) do
    {before, rest} = String.split_at(Table.value(nodes, text_id), offset)
    Table.set_value(nodes, text_id, before)
    tail = Table.create_text(nodes, rest)
    insert_after(nodes, Table.parent(nodes, text_id), tail, text_id)
    tail
  end

  defp insert_at_child_index(nodes, index, container, offset, node_id) do
    reference = Enum.at(Table.children(nodes, container), offset)
    insert_relative(nodes, index, container, node_id, reference)
  end

  # Insert node_id under parent before `reference` (append when nil), routing
  # through the tree-surgery workers so hierarchy + range adjustment run.
  defp insert_relative(nodes, index, parent_id, node_id, reference) do
    if reference do
      insert_before_op(nodes, index, parent_id, node_id, reference)
    else
      append_child_op(nodes, index, parent_id, node_id)
    end
  end

  @doc false
  def _range_surround_contents(server, range_id, element_id) do
    result =
      _atomic_ets_op(
        server,
        fn nodes, index ->
          range_surround_op(nodes, index, range_id, element_id)
        end,
        :mutates
      )

    case result do
      :ok -> :ok
      {:error, :invalid_state} -> raise DOM.InvalidStateError
    end
  end

  defp range_surround_op(nodes, index, range_id, element_id) do
    {sc, _so, ec, _eo} = range_endpoints!(nodes, index, range_id)

    if partially_selects_non_text?(nodes, sc, ec) do
      {:error, :invalid_state}
    else
      # extract -> append into element -> insert element at the range start
      fragment = range_extract_op(nodes, index, range_id)

      Enum.each(
        Table.children(nodes, fragment.node_id),
        &Table.append_child(nodes, element_id, &1)
      )

      Table.reindex(nodes, index)
      resync_spans(nodes, index)

      {{start_key, so2}, _} = Table.range_boundaries(index, range_id)
      container = Table.node_at_start_key(nodes, start_key)
      do_insert_at_boundary(nodes, index, container, so2, element_id)

      # select the inserted element
      select_element_in_range(nodes, index, range_id, element_id)
      :ok
    end
  end

  # A range partially selects a non-Text node when any PARTIALLY-CONTAINED node is
  # not character data. A node is partially contained when it contains one boundary
  # endpoint but not the other — i.e. the nodes on each boundary's path from the
  # container up to (excluding) the common ancestor. surroundContents forbids this.
  defp partially_selects_non_text?(nodes, sc, ec) do
    common = range_common_ancestor(nodes, sc, ec)

    (partially_contained_chain(nodes, sc, common) ++ partially_contained_chain(nodes, ec, common))
    |> Enum.any?(&(Table.type(nodes, &1) not in [:text, :comment]))
  end

  # The nodes from `boundary` up to (but not including) `common`.
  defp partially_contained_chain(_nodes, common, common), do: []

  defp partially_contained_chain(nodes, node, common) do
    case Table.parent(nodes, node) do
      ^common -> [node]
      nil -> [node]
      parent -> [node | partially_contained_chain(nodes, parent, common)]
    end
  end

  defp range_common_ancestor(nodes, a, b) do
    a_chain = ancestor_or_self_chain(nodes, a)
    b_set = MapSet.new(ancestor_or_self_chain(nodes, b))
    Enum.find(a_chain, &MapSet.member?(b_set, &1))
  end

  defp ancestor_or_self_chain(nodes, id) do
    case Table.parent(nodes, id) do
      nil -> [id]
      parent -> [id | ancestor_or_self_chain(nodes, parent)]
    end
  end

  # After surround, set the range to select `element_id` (start before, end after).
  defp select_element_in_range(nodes, index, range_id, element_id) do
    parent_id = Table.parent(nodes, element_id)
    at = child_index(nodes, parent_id, element_id)
    pkey = Table.fetch!(nodes, parent_id).start
    Table.range_put(index, range_id, {pkey, at}, {pkey, at + 1})
  end

  # Collapse `range_id` onto its start boundary (after extract/delete, per spec).
  defp collapse_range_to_start(index, range_id) do
    {{start_key, so}, _stop} = Table.range_boundaries(index, range_id)
    Table.range_put(index, range_id, {start_key, so}, {start_key, so})
  end

  # After an extract/delete that moved/removed nodes, re-pin every OTHER range's
  # boundaries whose container key changed (the generic remap), and drop boundaries
  # whose container no longer exists onto a still-live ancestor position. The
  # remap catches key changes; dangling boundaries are cleaned by re-resolving.
  defp reconcile_ranges(nodes, index, snapshot), do: apply_remap(nodes, index, snapshot)

  # Resolve a range's stored boundaries into `{start_container_id, start_offset,
  # end_container_id, end_offset}` via the extent-key reverse lookup.
  defp range_endpoints!(nodes, index, range_id) do
    {{start_key, so}, {stop_key, eo}} = Table.range_boundaries(index, range_id)
    {Table.node_at_start_key(nodes, start_key), so, Table.node_at_start_key(nodes, stop_key), eo}
  end

  # Insert `new_id` immediately after `ref_id` under `parent_id` (append if last).
  defp insert_after(nodes, parent_id, new_id, ref_id) do
    kids = Table.children(nodes, parent_id)
    at = Enum.find_index(kids, &(&1 == ref_id))

    case Enum.at(kids, at + 1) do
      nil -> Table.append_child(nodes, parent_id, new_id)
      next -> Table.insert_before(nodes, parent_id, new_id, next)
    end
  end

  # split rule (boundaries past the split move into the new node) + the insert of
  # the new sibling (a child was added after the original's index in the parent).
  defp adjust_split_ranges(_nodes, _index, nil, _parent, _orig, _ok, _nk, _off), do: :ok

  defp adjust_split_ranges(nodes, index, snapshot, parent_id, orig_id, orig_key, new_key, offset) do
    DOM.Range.Adjust.on_split(nodes, index, orig_key, new_key, offset)
    at = child_index(nodes, parent_id, orig_id)
    parent_key = Map.get(snapshot, parent_id) || current_start(nodes, parent_id)
    DOM.Range.Adjust.on_insert(nodes, index, parent_key, at, 1)
    :ok
  end

  @doc """
  Assert the document's ETS invariants (see `DOM.NodeData.Table.check_consistency!/1`),
  raising on violation. Test-only; wired into an `on_exit` hook by `DOM.Case`.
  """
  @spec _check_index_consistency!(GenServer.server()) :: :ok
  def _check_index_consistency!(server) do
    GenServer.call(server, :check_index_consistency)
  end

  defp check_index_consistency_impl(_from, state) do
    {:reply, Table.check_consistency!(state.nodes, state.index), state}
  end

  def _node_append_child(server, parent_id, %{server: child_server, node_id: child_id} = child) do
    result =
      if child_server == server do
        _atomic_ets_op(
          server,
          fn nodes, index ->
            append_child_op(nodes, index, parent_id, child_id)
          end,
          :mutates
        )
      else
        subtree = _export_subtree(child_server, child_id)

        result =
          _atomic_ets_op(
            server,
            fn nodes, index ->
              append_subtree_op(nodes, index, parent_id, child_id, subtree)
            end,
            :mutates
          )

        if match?({:ok, _transferred_child}, result) do
          _remove_subtree(child_server, child_id)
        end

        result
      end

    case result do
      :ok -> child
      {:ok, transferred_child} -> transferred_child
      {:error, :hierarchy_request} -> raise DOM.HierarchyRequestError
    end
  end

  defp append_child_op(nodes, index, parent_id, child_id) do
    child_data = fetch_node!(nodes, child_id)
    parent_data = fetch_node!(nodes, parent_id)

    cond do
      invalid_hierarchy?(nodes, parent_data, parent_id, child_data, child_id, nil, nil) ->
        {:error, :hierarchy_request}

      match?(%NodeData.DocumentFragment{}, child_data) ->
        append_fragment(nodes, parent_id, child_id, child_data)
        resync_spans(nodes, index)
        :ok

      :else ->
        snapshot = range_snapshot(nodes, index)
        siblings = Table.children(nodes, parent_id)
        at = length(siblings)
        Table.append_child(nodes, parent_id, child_id)
        resync_spans(nodes, index)
        adjust_ranges(nodes, index, snapshot, {:insert, parent_id, at, 1})
        _recompute_slots(nodes, index, child_id)
        # childList: appended at the end — previousSibling is the old last child.
        queue_child_list_record(nodes, index, parent_id, [child_id], [], List.last(siblings), nil)
        # custom element: connectedCallback for the inserted subtree, if now connected.
        if connected?(nodes, parent_id), do: custom_element_connected(nodes, child_id)
        :ok
    end
  end

  # Mirror the record extents (written live by the extent-authoritative mutators)
  # into the index's span rows after an incremental mutation. Idempotent; the
  # extents are the order source, so this only copies them — no carve from the
  # `children` field.
  defp resync_spans(nodes, index), do: Table.span_index_all(nodes, index)

  # Recompute slot assignment for the shadow host affected by a mutation, if any,
  # and signal slotchange on the slots that changed. `node_id` is a node touched by
  # the op (a light child of a host, or a slot in a shadow tree); Slots.affected_host
  # resolves which host's assignment to redo. Public (@doc false) so DOM.Element's
  # attribute path (slot=/name= changes) reuses it instead of duplicating the logic.
  @doc false
  def _recompute_slots(nodes, index, node_id) do
    if host = DOM.NodeData.Slots.affected_host(nodes, node_id) do
      signal_slots(index, DOM.NodeData.Slots.recompute(nodes, index, host))
    end

    :ok
  end

  # "Signal a slot" (HTML §slot): for each slot whose assignment CHANGED, enqueue a
  # slotchange microtask — but at most ONCE per slot per task. The `{:signaled_slot,
  # slot_id}` guard row dedups within a task; the microtask deletes it (so a change
  # in a later task re-signals) and dispatches slotchange at the slot. slotchange is
  # bubbles:true, composed:false, run from inside the drain loop (server == self()),
  # so its dispatch is a re-entrant in-place call.
  defp signal_slots(index, changed_slots) do
    for slot_id <- changed_slots, Table.signal_slot(index, slot_id) do
      _enqueue_microtask(self(), fn ->
        Table.unsignal_slot(Process.get(:index), slot_id)

        Events.dispatch(
          Process.get(:nodes),
          Process.get(:index),
          self(),
          slot_id,
          Event.new("slotchange", bubbles: true)
        )
      end)
    end

    :ok
  end

  # ==========================================================================
  # MutationObserver record emission
  # ==========================================================================
  #
  # Each mutating op, after mutating, calls one of the queue_* helpers below with
  # the CONCRETE change (target + old value / added-removed / siblings). We find
  # every observer whose observation matches this target — directly, or via an
  # ancestor observed with subtree — and whose options select this mutation type,
  # build a per-observer MutationRecord (honoring that observer's old-value flags
  # and attributeFilter), queue it, and signal the observer. "Signal" enqueues a
  # single "notify mutation observers" microtask per task (guarded like a slot
  # signal) that invokes each observer-with-records callback once with its batch.

  # childList: children of `target_id` changed. added/removed are id lists; prev/next
  # are the sibling ids bracketing the change (or nil).
  defp queue_child_list_record(nodes, index, target_id, added, removed, prev, next) do
    for {ref, _options} <- observers_of(nodes, index, target_id, :child_list) do
      record = %MutationRecord{
        type: :child_list,
        target: node_handle(nodes, target_id),
        added_nodes: Enum.map(added, &node_handle(nodes, &1)),
        removed_nodes: Enum.map(removed, &node_handle(nodes, &1)),
        previous_sibling: prev && node_handle(nodes, prev),
        next_sibling: next && node_handle(nodes, next)
      }

      queue_record(index, ref, record)
    end

    :ok
  end

  @doc false
  # Diff `before`/`after` attribute lists and emit one attributes record per changed
  # name (added, removed, or modified). @doc false so DOM.Element's attribute path
  # can call it across the module boundary. Only string (qualified-name) keys are
  # observable by name — namespaced triple keys are ignored, matching CSS/attr-index.
  def _queue_attribute_records(nodes, index, target_id, before, after_attrs) do
    b = for {k, v} <- before, is_binary(k), into: %{}, do: {k, v}
    a = for {k, v} <- after_attrs, is_binary(k), into: %{}, do: {k, v}

    names = Enum.uniq(Map.keys(b) ++ Map.keys(a))

    for name <- names, Map.get(b, name) != Map.get(a, name) do
      queue_attribute_record(nodes, index, target_id, name, Map.get(b, name))
    end

    :ok
  end

  # attributes: `name` on `target_id` changed; `old_value` is the prior value.
  defp queue_attribute_record(nodes, index, target_id, name, old_value) do
    for {ref, options} <- observers_of(nodes, index, target_id, :attributes),
        attribute_selected?(options, name) do
      record = %MutationRecord{
        type: :attributes,
        target: node_handle(nodes, target_id),
        attribute_name: name,
        old_value: if(options[:attribute_old_value], do: old_value)
      }

      queue_record(index, ref, record)
    end

    :ok
  end

  # characterData: the data of text/comment `target_id` changed; `old_value` prior.
  defp queue_character_data_record(nodes, index, target_id, old_value) do
    for {ref, options} <- observers_of(nodes, index, target_id, :character_data) do
      record = %MutationRecord{
        type: :character_data,
        target: node_handle(nodes, target_id),
        old_value: if(options[:character_data_old_value], do: old_value)
      }

      queue_record(index, ref, record)
    end

    :ok
  end

  # The {ref, options} of every observation that covers `target_id` for `kind`
  # (`:child_list`/`:attributes`/`:character_data`): the observed node is target_id
  # itself, or an ancestor observed with subtree. The matching kind option must be set.
  defp observers_of(nodes, index, target_id, kind) do
    ancestors = MapSet.new(ancestor_ids(nodes, target_id))

    for {ref, observed_id, options} <- Table.observations(index),
        Map.get(options, kind),
        observed_id == target_id or
          (options[:subtree] and MapSet.member?(ancestors, observed_id)),
        do: {ref, options}
  end

  # `target_id` and every ancestor up to the document root.
  defp ancestor_ids(nodes, node_id) do
    case Table.parent(nodes, node_id) do
      nil -> [node_id]
      parent_id -> [node_id | ancestor_ids(nodes, parent_id)]
    end
  end

  defp attribute_selected?(options, name) do
    case options[:attribute_filter] do
      nil -> true
      filter -> name in filter
    end
  end

  # Queue a record on `ref` and enqueue the per-task "notify" microtask once.
  defp queue_record(index, ref, record) do
    Table.mo_record_put(index, ref, record)
    signal_notify_observers(index)
  end

  # Enqueue the single "notify mutation observers" microtask for this task (guarded
  # by a {:signaled_slot, :mo_notify} row so N records enqueue ONE notify). The
  # microtask clears the guard, then for each observer with queued records invokes
  # its callback once with the drained batch (re-entrantly, server == self()).
  defp signal_notify_observers(index) do
    if Table.signal_slot(index, :mo_notify) do
      _enqueue_microtask(self(), &notify_mutation_observers/0)
    end

    :ok
  end

  defp notify_mutation_observers do
    index = Process.get(:index)
    Table.unsignal_slot(index, :mo_notify)

    for ref <- Table.mo_record_refs(index) do
      records = Table.mo_take_records(index, ref)
      callback = Table.observer_callback(index, ref)
      if records != [] && callback, do: callback.(records)
    end

    :ok
  end

  # A snapshot of every node's start key, captured BEFORE a structural mutation so
  # live-range adjustment can (a) remap boundaries whose container's key changed
  # (graft) and (b) find a parent/removed container by its pre-mutation key.
  defp range_snapshot(nodes, index) do
    if Table.range_all_rows(index) == [] do
      nil
    else
      for {id, %{start: start}} when start != nil <- :ets.tab2list(nodes),
          into: %{},
          do: {id, start}
    end
  end

  # Apply live-range adjustment after a structural op, given the pre-mutation
  # `snapshot` (nil when no ranges exist — a fast no-op). `op` describes the edit:
  #   {:insert, parent_id, at_index, count} | {:remove, parent_id, at_index, removed_id}
  # The remap (containers whose start key changed) always runs; then the op's
  # child-index offset rule.
  defp adjust_ranges(_nodes, _index, nil, _op), do: :ok

  defp adjust_ranges(nodes, index, snapshot, op) do
    apply_remap(nodes, index, snapshot)
    apply_offset_rule(nodes, index, snapshot, op)
    :ok
  end

  # Remap boundaries whose container node's start key changed between the snapshot
  # and now (a graft moved the container / its subtree).
  defp apply_remap(nodes, index, snapshot) do
    remap =
      for {id, old_key} <- snapshot,
          new = current_start(nodes, id),
          new != nil and new != old_key,
          into: %{},
          do: {old_key, new}

    if remap != %{}, do: DOM.Range.Adjust.on_remap(nodes, index, remap)
  end

  defp current_start(nodes, id) do
    case :ets.lookup(nodes, id) do
      [{^id, %{start: start}}] -> start
      _ -> nil
    end
  end

  defp apply_offset_rule(nodes, index, snapshot, {:insert, parent_id, at, count}) do
    parent_key = Map.get(snapshot, parent_id) || current_start(nodes, parent_id)
    DOM.Range.Adjust.on_insert(nodes, index, parent_key, at, count)
  end

  defp apply_offset_rule(nodes, index, snapshot, {:remove, parent_id, at, removed_keys}) do
    parent_key = Map.get(snapshot, parent_id) || current_start(nodes, parent_id)
    DOM.Range.Adjust.on_remove(nodes, index, parent_key, at, removed_keys)
  end

  # Flatten a fragment's children onto `parent_id` (append), placing all of them in
  # one multispan-carved gap (snapshot the ordered children first — the bulk move
  # re-parents them, emptying the fragment).
  defp append_fragment(nodes, parent_id, fragment_id, _fragment) do
    Table.append_children(nodes, parent_id, Table.children(nodes, fragment_id))
  end

  # Flatten a fragment's children into `parent_id` before `reference_child_id`, in
  # order, in one multispan-carved gap.
  defp insert_fragment(nodes, parent_id, fragment_id, _fragment, reference_child_id) do
    Table.insert_children_before(
      nodes,
      parent_id,
      Table.children(nodes, fragment_id),
      reference_child_id
    )
  end

  def _node_insert_before(server, parent_id, child, nil) do
    _node_append_child(server, parent_id, child)
  end

  def _node_insert_before(
        server,
        parent_id,
        %{server: child_server, node_id: child_id} = child,
        %{node_id: reference_child_id}
      ) do
    result =
      if child_server == server do
        _atomic_ets_op(
          server,
          fn nodes, index ->
            insert_before_op(nodes, index, parent_id, child_id, reference_child_id)
          end,
          :mutates
        )
      else
        subtree = _export_subtree(child_server, child_id)

        result =
          _atomic_ets_op(
            server,
            fn nodes, index ->
              insert_subtree_op(nodes, index, parent_id, child_id, reference_child_id, subtree)
            end,
            :mutates
          )

        if match?({:ok, _transferred_child}, result) do
          _remove_subtree(child_server, child_id)
        end

        result
      end

    case result do
      :ok -> child
      {:ok, transferred_child} -> transferred_child
      {:error, :hierarchy_request} -> raise DOM.HierarchyRequestError
      {:error, :not_found} -> raise DOM.NotFoundError
    end
  end

  defp insert_before_op(nodes, index, parent_id, child_id, reference_child_id) do
    child_data = fetch_node!(nodes, child_id)
    parent_data = fetch_node!(nodes, parent_id)

    cond do
      inclusive_ancestor?(nodes, child_id, parent_id) ->
        {:error, :hierarchy_request}

      reference_child_id not in Table.children(nodes, parent_id) ->
        {:error, :not_found}

      invalid_hierarchy?(
        nodes,
        parent_data,
        parent_id,
        child_data,
        child_id,
        reference_child_id,
        nil
      ) ->
        {:error, :hierarchy_request}

      child_id == reference_child_id ->
        :ok

      match?(%NodeData.DocumentFragment{}, child_data) ->
        insert_fragment(nodes, parent_id, child_id, child_data, reference_child_id)
        resync_spans(nodes, index)
        :ok

      :else ->
        snapshot = range_snapshot(nodes, index)
        siblings = Table.children(nodes, parent_id)
        at = child_index(nodes, parent_id, reference_child_id)
        Table.insert_before(nodes, parent_id, child_id, reference_child_id)
        resync_spans(nodes, index)
        adjust_ranges(nodes, index, snapshot, {:insert, parent_id, at, 1})
        _recompute_slots(nodes, index, child_id)
        # childList: inserted before the reference — previousSibling is the child
        # that preceded the reference (nil when inserting at the front).
        prev = if at > 0, do: Enum.at(siblings, at - 1)
        queue_child_list_record(nodes, index, parent_id, [child_id], [], prev, reference_child_id)
        # custom element: connectedCallback for the inserted subtree, if now connected.
        if connected?(nodes, parent_id), do: custom_element_connected(nodes, child_id)
        :ok
    end
  end

  defp append_subtree_op(nodes, index, parent_id, child_id, subtree) do
    subtree_nodes = Map.new(subtree)
    child_data = Map.fetch!(subtree_nodes, child_id)
    parent_data = fetch_node!(nodes, parent_id)

    if invalid_hierarchy?(nodes, parent_data, parent_id, child_data, child_id, nil, subtree_nodes) do
      {:error, :hierarchy_request}
    else
      materialize_subtree(nodes, index, child_id, subtree)

      if match?(%NodeData.DocumentFragment{}, child_data) do
        append_fragment(nodes, parent_id, child_id, child_data)
      else
        Table.append_child(nodes, parent_id, child_id)
      end

      resync_spans(nodes, index)
      {:ok, node_handle(nodes, child_id)}
    end
  end

  defp insert_subtree_op(nodes, index, parent_id, child_id, reference_child_id, subtree) do
    subtree_nodes = Map.new(subtree)
    child_data = Map.fetch!(subtree_nodes, child_id)
    parent_data = fetch_node!(nodes, parent_id)

    cond do
      reference_child_id not in Table.children(nodes, parent_id) ->
        {:error, :not_found}

      invalid_hierarchy?(
        nodes,
        parent_data,
        parent_id,
        child_data,
        child_id,
        reference_child_id,
        subtree_nodes
      ) ->
        {:error, :hierarchy_request}

      :else ->
        materialize_subtree(nodes, index, child_id, subtree)

        if match?(%NodeData.DocumentFragment{}, child_data) do
          insert_fragment(nodes, parent_id, child_id, child_data, reference_child_id)
        else
          Table.insert_before(nodes, parent_id, child_id, reference_child_id)
        end

        resync_spans(nodes, index)
        {:ok, node_handle(nodes, child_id)}
    end
  end

  defp materialize_subtree(nodes, index, child_id, subtree) do
    subtree =
      Enum.map(subtree, fn
        {^child_id, node_data} -> {child_id, %{node_data | parent: nil}}
        entry -> entry
      end)

    true = :ets.insert(nodes, subtree)
    Enum.each(subtree, fn {id, node_data} -> index_element(index, id, node_data) end)
  end

  @doc false
  # adoptNode: move `node_id` into `dst_server`, detached. Same server → just detach
  # it in place; cross server → export, materialize into dst, remove from source.
  def _adopt_node(dst_server, dst_server, node_id) do
    _atomic_ets_op(
      dst_server,
      fn nodes, index ->
        node_data = fetch_node!(nodes, node_id)
        detach_from_parent(nodes, node_id, node_data)
        resync_spans(nodes, index)
        node_handle(nodes, node_id)
      end,
      :mutates
    )
  end

  def _adopt_node(dst_server, src_server, node_id) do
    subtree = _export_subtree(src_server, node_id)
    # custom element: disconnectedCallback in the SOURCE for the (formerly connected)
    # subtree, before removing it there.
    src_doc = _adopt_disconnect(src_server, node_id)

    handle =
      _atomic_ets_op(
        dst_server,
        fn nodes, index ->
          materialize_subtree(nodes, index, node_id, subtree)
          resync_spans(nodes, index)
          # custom element: adoptedCallback in the DESTINATION (its registry governs),
          # passing (element, old_document, new_document).
          custom_element_adopted(nodes, node_id, src_doc)
          node_handle(nodes, node_id)
        end,
        :mutates
      )

    _remove_subtree(src_server, node_id)
    handle
  end

  # In the SOURCE server: fire disconnectedCallback for the connected custom elements
  # in `node_id`'s subtree (they are about to leave the document). Returns the source
  # document handle (the adoptedCallback's old_document).
  defp _adopt_disconnect(src_server, node_id) do
    _atomic_ets_op(src_server, fn nodes, _index ->
      disconnecting = capture_disconnecting_root(nodes, node_id)
      custom_element_disconnected(nodes, disconnecting)
      document_handle(nodes, Process.get(:document_id))
    end)
  end

  @doc false
  # importNode: copy `node_id` (deep when `deep?`) into `dst_server`, detached,
  # leaving the source intact. Same server → Table.clone; cross server → export a
  # (possibly shallow) snapshot and materialize a fresh-keyed copy into dst.
  def _import_node(dst_server, dst_server, node_id, deep?) do
    _atomic_ets_op(
      dst_server,
      fn nodes, index ->
        clone_id = Table.clone(nodes, node_id, deep?)
        Table.reindex(nodes, index)
        Table.span_index_all(nodes, index)
        node_handle(nodes, clone_id)
      end,
      :mutates
    )
  end

  def _import_node(dst_server, src_server, node_id, deep?) do
    subtree = _export_subtree(src_server, node_id)
    subtree = if deep?, do: subtree, else: shallow_subtree(subtree, node_id)
    {rekeyed, new_root} = rekey_subtree(subtree, node_id)

    _atomic_ets_op(
      dst_server,
      fn nodes, index ->
        materialize_subtree(nodes, index, new_root, rekeyed)
        resync_spans(nodes, index)
        node_handle(nodes, new_root)
      end,
      :mutates
    )
  end

  # Keep only the root record from an exported subtree (shallow import).
  defp shallow_subtree(subtree, root_id) do
    subtree
    |> Enum.filter(fn {id, _rec} -> id == root_id end)
    |> Enum.map(fn {id, rec} -> {id, %{rec | start: <<0x00>>, stop: <<0x80>>}} end)
  end

  # Re-key an exported subtree to fresh refs (so an import is independent of its
  # source), rewriting parent pointers. Returns {rekeyed_entries, new_root_id}.
  defp rekey_subtree(subtree, root_id) do
    mapping = Map.new(subtree, fn {id, _rec} -> {id, make_ref()} end)

    rekeyed =
      Enum.map(subtree, fn {id, rec} ->
        parent = rec.parent && Map.get(mapping, rec.parent)
        {Map.fetch!(mapping, id), %{rec | parent: parent}}
      end)

    {rekeyed, Map.fetch!(mapping, root_id)}
  end

  def _node_remove_child(server, parent_id, %{node_id: child_id} = child) do
    result =
      _atomic_ets_op(
        server,
        fn nodes, index ->
          remove_child_op(nodes, index, parent_id, child_id)
        end,
        :mutates
      )

    case result do
      :ok -> child
      {:error, :not_found} -> raise DOM.NotFoundError
    end
  end

  defp remove_child_op(nodes, index, parent_id, child_id) do
    if child_id in Table.children(nodes, parent_id) do
      snapshot = range_snapshot(nodes, index)
      siblings = Table.children(nodes, parent_id)
      at = child_index(nodes, parent_id, child_id)
      removed_keys = removed_subtree_keys(nodes, child_id)
      # custom element: capture the connected custom elements in the subtree BEFORE
      # detaching (with their defs), to fire disconnectedCallback after.
      disconnecting = capture_disconnecting(nodes, parent_id, child_id)

      Table.remove_child(nodes, parent_id, child_id)
      resync_spans(nodes, index)
      adjust_ranges(nodes, index, snapshot, {:remove, parent_id, at, removed_keys})
      # The removed node's parent may be a shadow host (or the removed subtree may
      # contain slots) — recompute assignment from the parent directly.
      if Slots.shadow_host?(nodes, parent_id) do
        signal_slots(index, Slots.recompute(nodes, index, parent_id))
      end

      # childList: the removed node with the siblings that bracketed it.
      prev = if at > 0, do: Enum.at(siblings, at - 1)
      next = Enum.at(siblings, at + 1)
      queue_child_list_record(nodes, index, parent_id, [], [child_id], prev, next)
      # custom element: disconnectedCallback for the (formerly connected) subtree.
      custom_element_disconnected(nodes, disconnecting)
      :ok
    else
      {:error, :not_found}
    end
  end

  # The index of `child_id` among `parent_id`'s children (document order).
  defp child_index(nodes, parent_id, child_id) do
    nodes |> Table.children(parent_id) |> Enum.find_index(&(&1 == child_id))
  end

  # The set of start keys of `id` and its descendants (a removed subtree's keys),
  # for relocating boundaries that were inside it.
  defp removed_subtree_keys(nodes, id) do
    [id | Table.descendant_ids(nodes, id)]
    |> Enum.map(&current_start(nodes, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  def _node_replace_child(
        server,
        parent_id,
        %{server: new_server, node_id: new_child_id},
        %{node_id: old_child_id} = old_child
      ) do
    result =
      if new_server == server do
        _atomic_ets_op(
          server,
          fn nodes, index ->
            replace_child_op(nodes, index, parent_id, new_child_id, old_child_id)
          end,
          :mutates
        )
      else
        subtree = _export_subtree(new_server, new_child_id)

        result =
          _atomic_ets_op(
            server,
            fn nodes, index ->
              replace_subtree_op(nodes, index, parent_id, new_child_id, old_child_id, subtree)
            end,
            :mutates
          )

        if match?({:ok, _replaced}, result) do
          _remove_subtree(new_server, new_child_id)
        end

        result
      end

    case result do
      {:ok, _replaced} -> old_child
      {:error, :hierarchy_request} -> raise DOM.HierarchyRequestError
      {:error, :not_found} -> raise DOM.NotFoundError
    end
  end

  defp replace_child_op(nodes, index, parent_id, new_child_id, old_child_id) do
    new_child_data = fetch_node!(nodes, new_child_id)
    parent_data = fetch_node!(nodes, parent_id)

    replace_child_common(
      nodes,
      index,
      parent_id,
      parent_data,
      new_child_id,
      new_child_data,
      old_child_id,
      nil,
      fn -> detach_from_parent(nodes, new_child_id, new_child_data) end
    )
  end

  defp replace_subtree_op(nodes, index, parent_id, new_child_id, old_child_id, subtree) do
    subtree_nodes = Map.new(subtree)
    new_child_data = Map.fetch!(subtree_nodes, new_child_id)
    parent_data = fetch_node!(nodes, parent_id)

    replace_child_common(
      nodes,
      index,
      parent_id,
      parent_data,
      new_child_id,
      new_child_data,
      old_child_id,
      subtree_nodes,
      fn -> materialize_subtree(nodes, index, new_child_id, subtree) end
    )
  end

  # Shared replaceChild body. `prepare` either detaches a same-document new
  # child from its old parent or materializes a transferred subtree; the
  # document validity check excludes `old_child_id`, which is leaving.
  defp replace_child_common(
         nodes,
         index,
         parent_id,
         parent_data,
         new_child_id,
         new_child_data,
         old_child_id,
         subtree_nodes,
         prepare
       ) do
    cond do
      old_child_id not in Table.children(nodes, parent_id) ->
        {:error, :not_found}

      new_child_id == old_child_id ->
        {:ok, node_handle(nodes, new_child_id)}

      invalid_hierarchy?(
        nodes,
        parent_data,
        parent_id,
        new_child_data,
        old_child_id,
        old_child_id,
        subtree_nodes
      ) ->
        {:error, :hierarchy_request}

      :else ->
        prepare.()
        # Splice the replacement in immediately before old_child (each moved node
        # via the extent-authoritative insert_before, so extents land in old's
        # neighborhood), then remove old_child — leaving its gap.
        if match?(%NodeData.DocumentFragment{}, new_child_data) do
          insert_fragment(nodes, parent_id, new_child_id, new_child_data, old_child_id)
        else
          Table.insert_before(nodes, parent_id, new_child_id, old_child_id)
        end

        Table.remove_child(nodes, parent_id, old_child_id)
        resync_spans(nodes, index)
        {:ok, node_handle(nodes, new_child_id)}
    end
  end

  def _export_subtree(server, node_id) do
    _atomic_ets_op(server, fn nodes, _index -> subtree(nodes, node_id) end)
  end

  def _remove_subtree(server, node_id) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        node_data = fetch_node!(nodes, node_id)
        detach_from_parent(nodes, node_id, node_data)
        delete_subtree(nodes, index, node_id)
        resync_spans(nodes, index)
        :ok
      end,
      :mutates
    )
  end

  defp invalid_hierarchy?(nodes, parent, parent_id, child, child_id, reference_child_id, subtree) do
    inclusive_ancestor?(nodes, child_id, parent_id) or
      (match?(%NodeData.Document{}, parent) and
         invalid_document_child?(nodes, parent_id, child, child_id, reference_child_id, subtree))
  end

  # `document_id` is the document (parent) being inserted into; its ordered children
  # come from the extent index (Table.children), not a record field.
  defp invalid_document_child?(
         nodes,
         document_id,
         %NodeData.Element{},
         child_id,
         reference_child_id,
         _sub
       ) do
    document_has_kind?(nodes, document_id, NodeData.Element, child_id) or
      doctype_at_or_after?(nodes, document_id, reference_child_id)
  end

  defp invalid_document_child?(
         nodes,
         document_id,
         %NodeData.DocumentType{},
         child_id,
         reference_id,
         _sub
       ) do
    document_has_kind?(nodes, document_id, NodeData.DocumentType, child_id) or
      element_before?(nodes, document_id, reference_id)
  end

  defp invalid_document_child?(
         nodes,
         document_id,
         %NodeData.DocumentFragment{},
         fragment_id,
         _reference_child_id,
         subtree
       ) do
    invalid_document_fragment?(nodes, document_id, fragment_id, subtree)
  end

  defp invalid_document_child?(_nodes, _document_id, _child, _child_id, _reference_child_id, _sub) do
    false
  end

  # An element precedes the insertion point: with a nil reference (append), any
  # element counts; otherwise only elements before the reference child.
  defp element_before?(nodes, document_id, reference_child_id) do
    nodes
    |> Table.children(document_id)
    |> Enum.take_while(&(&1 != reference_child_id))
    |> Enum.any?(&match?(%NodeData.Element{}, fetch_node!(nodes, &1)))
  end

  # A doctype sits at or after the insertion point: with a nil reference
  # (append), any doctype counts; otherwise doctypes from the reference child on.
  defp doctype_at_or_after?(nodes, document_id, reference_child_id) do
    nodes
    |> Table.children(document_id)
    |> Enum.drop_while(&(&1 != reference_child_id))
    |> Enum.any?(&match?(%NodeData.DocumentType{}, fetch_node!(nodes, &1)))
  end

  defp invalid_document_fragment?(nodes, document_id, fragment_id, subtree_nodes) do
    kinds =
      Enum.map(fragment_children(nodes, fragment_id, subtree_nodes), fn child_id ->
        node_kind(nodes, child_id, subtree_nodes)
      end)

    element_count = Enum.count(kinds, &(&1 == NodeData.Element))

    NodeData.Text in kinds or
      element_count > 1 or
      (element_count == 1 and document_has_kind?(nodes, document_id, NodeData.Element, nil))
  end

  # A fragment's children: from the live extents (same-doc), else from the
  # transported subtree map — derived by parent pointer + extent order, since the
  # records carry `parent`/`start`, not a `children` field.
  defp fragment_children(nodes, fragment_id, nil), do: Table.children(nodes, fragment_id)

  defp fragment_children(_nodes, fragment_id, subtree_nodes) do
    subtree_nodes
    |> Enum.filter(fn {_id, data} -> data.parent == fragment_id end)
    |> Enum.sort_by(fn {_id, data} -> data.start end)
    |> Enum.map(fn {id, _data} -> id end)
  end

  # The NodeData struct MODULE of a node (used as a kind discriminator).
  defp node_kind(nodes, node_id, nil), do: fetch_node!(nodes, node_id).__struct__

  defp node_kind(_nodes, node_id, subtree_nodes),
    do: Map.fetch!(subtree_nodes, node_id).__struct__

  defp document_has_kind?(nodes, document_id, kind, except_id) do
    nodes
    |> Table.children(document_id)
    |> Enum.any?(fn node_id ->
      node_id != except_id and fetch_node!(nodes, node_id).__struct__ == kind
    end)
  end

  defp detach_from_parent(nodes, child_id, _child) do
    Table.detach(nodes, child_id)
  end

  defp inclusive_ancestor?(nodes, ancestor_id, node_id) do
    cond do
      ancestor_id == node_id ->
        true

      parent_id = fetch_node!(nodes, node_id).parent ->
        inclusive_ancestor?(nodes, ancestor_id, parent_id)

      :else ->
        false
    end
  end

  def _node_owner_document(server, node_id) do
    _atomic_ets_op(server, fn _nodes, _index ->
      document_id = Process.get(:document_id)

      if node_id != document_id do
        %Node{server: server, node_id: document_id, type: :document}
      end
    end)
  end

  def _node_clone_node(server, node_id, deep?) do
    _atomic_ets_op(server, fn nodes, index ->
      clone_id = Table.clone(nodes, node_id, deep?)
      Table.reindex(nodes, index)
      Table.span_index_all(nodes, index)
      node_handle(nodes, clone_id)
    end)
  end

  @doc false
  # `node` contains `other` iff `other` is `node` or a descendant of it.
  def _node_contains(server, node_id, other_id) do
    _atomic_ets_op(server, fn nodes, _index ->
      other_id == node_id or other_id in Table.descendant_ids(nodes, node_id)
    end)
  end

  @doc false
  def _node_is_equal(node_server, node_id, other_server, other_id) do
    # Structural equality can span two servers; snapshot the other subtree and
    # compare against this one's live table.
    other_snapshot = Map.new(_export_subtree(other_server, other_id))

    _atomic_ets_op(node_server, fn nodes, _index ->
      equal_node?(nodes, node_id, other_snapshot, other_id)
    end)
  end

  @doc false
  # DOCUMENT_POSITION_* bitmask relating `other` to `node`. Same-server only for a
  # meaningful order; different servers are DISCONNECTED.
  def _node_compare_document_position(node_server, _node_id, other_server, _other_id)
      when node_server != other_server do
    # DISCONNECTED (1) + IMPLEMENTATION_SPECIFIC (32) + a stable direction (PRECEDING 2)
    1 + 32 + 2
  end

  def _node_compare_document_position(server, node_id, _other_server, other_id) do
    _atomic_ets_op(server, fn nodes, _index ->
      compare_document_position(nodes, node_id, other_id)
    end)
  end

  @doc false
  def _node_normalize(server, node_id) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        normalize_subtree(nodes, index, node_id)
        :ok
      end,
      :mutates
    )
  end

  # Normalize `node_id`'s subtree: merge each maximal run of adjacent Text children
  # into its first (concatenating values), drop empty Text children, then recurse
  # into element/fragment children. Removals ride remove_child_op so live-range
  # boundaries and slot assignment are maintained.
  defp normalize_subtree(nodes, index, node_id) do
    merge_text_runs(Table.children(nodes, node_id), nodes, index, node_id)

    # recurse into the (possibly changed) element/fragment children
    for child <- Table.children(nodes, node_id),
        Table.type(nodes, child) not in [:text, :comment] do
      normalize_subtree(nodes, index, child)
    end

    :ok
  end

  # Walk the child list once: accumulate the current Text-run head; fold each
  # following adjacent Text into it and remove that follower; a non-Text child ends
  # the run. A leading/standalone empty Text is removed outright (an empty follower
  # is folded in — appending "" — then removed, which also drops it).
  defp merge_text_runs(children, nodes, index, parent_id) do
    # The fold threads the current run's head id (or nil); its final value is
    # irrelevant — the work is the ETS mutations performed along the way.
    Enum.reduce(children, nil, fn child, run_head ->
      cond do
        Table.type(nodes, child) != :text ->
          nil

        run_head == nil and Table.value(nodes, child) == "" ->
          remove_child_op(nodes, index, parent_id, child)
          nil

        run_head == nil ->
          child

        :else ->
          merged = Table.value(nodes, run_head) <> Table.value(nodes, child)
          Table.set_value(nodes, run_head, merged)
          remove_child_op(nodes, index, parent_id, child)
          run_head
      end
    end)
  end

  @doc false
  # Registering the same (type, fn, capture) twice is a no-op (DOM semantics):
  # retract any existing match first, then insert.
  def _node_add_event_listener(server, node_id, %DOM.Listener{} = listener) do
    _atomic_ets_op(server, fn _nodes, index ->
      Table.listener_delete(index, node_id, listener.type, listener.fn, listener.capture)
      Table.listener_put(index, node_id, listener)
      :ok
    end)
  end

  @doc false
  def _node_remove_event_listener(server, node_id, type, fun, capture) do
    _atomic_ets_op(server, fn _nodes, index ->
      Table.listener_delete(index, node_id, type, fun, capture)
      :ok
    end)
  end

  @doc false
  def _node_listeners(server, node_id) do
    _atomic_ets_op(server, fn _nodes, index -> Table.listeners_of(index, node_id) end)
  end

  @doc false
  # Dispatch runs listeners (which may call DOM ops re-entrantly). It has its OWN
  # handle_call (not _atomic_ets_op) so that only enqueue + dispatch — the two ops
  # that populate the microtask queue — carry the {:continue, :drain_microtasks}
  # checkpoint; every other atomic op stays checkpoint-free. Dual: from INSIDE the
  # server (a listener synchronously dispatching another event) it runs in-place —
  # plain stack recursion, no checkpoint, inheriting the outer frame's drain.
  def _node_dispatch_event(server, node_id, event) do
    if server == self(),
      do: dispatch_with_default(Process.get(:nodes), Process.get(:index), node_id, event),
      else: GenServer.call(server, {:dispatch_event, node_id, event})
  end

  defp dispatch_event_impl(node_id, event, _from, state) do
    result = dispatch_with_default(state.nodes, state.index, node_id, event)
    {:reply, result, state, {:continue, :drain_microtasks}}
  end

  # Dispatch, then run the event's default action UNLESS it was prevented. `dispatch`
  # returns `not default_prevented`, which is both the dispatchEvent boolean and the
  # "run the default action?" gate. Runs in-server (both dispatch paths funnel here).
  defp dispatch_with_default(nodes, index, node_id, event) do
    not_prevented = Events.dispatch(nodes, index, self(), node_id, event)
    if not_prevented, do: run_default_action(nodes, index, node_id, event)
    not_prevented
  end

  # The activation behavior for a dispatched event. Currently: a `click` on a
  # checkbox/radio input toggles its checkedness (checkbox toggles; radio sets true and
  # clears the rest of its name group). Other events have no default action yet.
  defp run_default_action(nodes, index, node_id, %Event{type: "click"}) do
    case fetch_node!(nodes, node_id) do
      %NodeData.Element{local_name: "input"} = el ->
        toggle_input_checkedness(nodes, index, node_id, el)

      %NodeData.Element{local_name: "summary"} ->
        toggle_details(nodes, index, node_id)

      _ ->
        :ok
    end
  end

  defp run_default_action(_nodes, _index, _node_id, _event), do: :ok

  # A click on a <summary> toggles its parent <details>'s `open` attribute.
  defp toggle_details(nodes, index, summary_id) do
    parent_id = Table.parent(nodes, summary_id)

    if parent_id &&
         match?(%NodeData.Element{local_name: "details"}, fetch_node!(nodes, parent_id)) do
      if Table.has_attribute(nodes, parent_id, "open") do
        Table.remove_attribute(nodes, parent_id, "open")
      else
        Table.set_attribute(nodes, parent_id, "open", "")
      end

      Table.index_put(index, parent_id, fetch_node!(nodes, parent_id))
    end

    :ok
  end

  defp toggle_input_checkedness(nodes, index, node_id, el) do
    case input_type(el) do
      "checkbox" ->
        clear_indeterminate(nodes, index, node_id)
        set_checkedness(nodes, index, node_id, not effective_checkedness(el))

      "radio" ->
        clear_radio_group(nodes, index, node_id, el)
        set_checkedness(nodes, index, node_id, true)

      _ ->
        :ok
    end
  end

  # A click on a checkbox clears its indeterminate property (browser-verified).
  defp clear_indeterminate(nodes, index, node_id) do
    record = fetch_node!(nodes, node_id)

    if record.indeterminate do
      updated = %{record | indeterminate: false}
      :ets.insert(nodes, {node_id, updated})
      Table.index_put(index, node_id, updated)
    end

    :ok
  end

  # An input's current checkedness: the override field (dirty), else the `checked`
  # attribute (clean default).
  defp effective_checkedness(%NodeData.Element{checked: nil} = el),
    do: has_string_attr?(el, "checked")

  defp effective_checkedness(%NodeData.Element{checked: value}), do: value

  defp input_type(%NodeData.Element{} = el), do: get_string_attr(el, "type") || "text"

  # Set the checkedness override (dirty) on `node_id`.
  defp set_checkedness(nodes, index, node_id, value) do
    record = fetch_node!(nodes, node_id)
    updated = %{record | checked: value}
    :ets.insert(nodes, {node_id, updated})
    Table.index_put(index, node_id, updated)
    :ok
  end

  # Uncheck every OTHER radio in `el`'s name group (same `name`, same tree/form scope).
  # Scope: the connected radios in the document with the same name (a coarse but correct
  # grouping for a single-form document; form-scoped grouping can refine this later).
  defp clear_radio_group(nodes, index, node_id, el) do
    name = get_string_attr(el, "name")

    if name do
      for other <- radios_named(nodes, name), other != node_id do
        set_checkedness(nodes, index, other, false)
      end
    end

    :ok
  end

  defp radios_named(nodes, name) do
    for id <- Table.elements_by_tag_name(nodes, Process.get(:document_id), "input"),
        el = fetch_node!(nodes, id),
        input_type(el) == "radio",
        get_string_attr(el, "name") == name,
        do: id
  end

  @doc false
  # Flip one flag on an in-flight event's :active_event row (from a listener's
  # prevent_default/stop_*). Re-entrant: the listener runs inside this same server.
  def _event_set_flag(server, ref, flag) do
    _atomic_ets_op(server, fn _nodes, index -> Table.active_event_set(index, ref, flag) end)
  end

  @doc false
  def _node_composed_path(server, node_id, composed?) do
    _atomic_ets_op(server, fn nodes, _index ->
      nodes
      |> Events.propagation_path(node_id, composed?)
      |> Enum.map(fn {id, _retarget} -> node_handle(nodes, id) end)
    end)
  end

  def _element_inner_html(server, node_id) do
    _atomic_ets_op(server, fn nodes, _index ->
      element = fetch_node!(nodes, node_id)
      child_ids = Table.children_by_extent(nodes, node_id)
      IO.iodata_to_binary(DOM.HTML.children(element.local_name, child_ids, nodes))
    end)
  end

  @doc false
  # innerHTML setter (§): fragment-parse `html` with this element as the context,
  # then replace the element's children with the parsed fragment's children. All
  # in-process on this server's table via DOM.NodeData.Table.
  def _element_set_inner_html(server, node_id, html) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        element = Table.fetch!(nodes, node_id)
        context = %{name: element.local_name, namespace: element.namespace}
        root = fragment_root_for(html, context, nodes, index, Process.get(:document_id))

        Enum.each(Table.children(nodes, node_id), &Table.remove_child(nodes, node_id, &1))
        Table.append_children(nodes, node_id, Table.children(nodes, root))
        resync_spans(nodes, index)
        :ok
      end,
      :mutates
    )
  end

  @doc false
  # insertAdjacentHTML: parse `html` (context = the element for child positions, its
  # parent for sibling positions) then splice the parsed nodes at `position`.
  def _element_insert_adjacent_html(server, node_id, position, html) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        context_id = adjacent_context_id(nodes, node_id, position)
        context_el = Table.fetch!(nodes, context_id)
        context = %{name: context_el.local_name, namespace: context_el.namespace}
        root = fragment_root_for(html, context, nodes, index, Process.get(:document_id))
        parsed = Table.children(nodes, root)

        insert_adjacent(nodes, index, node_id, position, parsed)
        resync_spans(nodes, index)
        :ok
      end,
      :mutates
    )
  end

  # The fragment-parse context element for a position (element itself for child
  # positions, its parent for sibling positions).
  defp adjacent_context_id(_nodes, node_id, position) when position in ~w(afterbegin beforeend),
    do: node_id

  defp adjacent_context_id(nodes, node_id, _sibling), do: Table.parent(nodes, node_id)

  # Splice `parsed` child ids at the adjacency position relative to `node_id`.
  defp insert_adjacent(nodes, _index, node_id, "afterbegin", parsed) do
    case List.first(Table.children(nodes, node_id)) do
      nil -> Table.append_children(nodes, node_id, parsed)
      reference -> Table.insert_children_before(nodes, node_id, parsed, reference)
    end
  end

  defp insert_adjacent(nodes, _index, node_id, "beforeend", parsed) do
    Table.append_children(nodes, node_id, parsed)
  end

  defp insert_adjacent(nodes, _index, node_id, "beforebegin", parsed) do
    parent = Table.parent(nodes, node_id)
    Table.insert_children_before(nodes, parent, parsed, node_id)
  end

  defp insert_adjacent(nodes, _index, node_id, "afterend", parsed) do
    parent = Table.parent(nodes, node_id)

    case Enum.at(Table.children(nodes, parent), child_index(nodes, parent, node_id) + 1) do
      nil -> Table.append_children(nodes, parent, parsed)
      reference -> Table.insert_children_before(nodes, parent, parsed, reference)
    end
  end

  @doc false
  # A shadow root has no tag; serialize its children with an empty container name
  # (so no raw-text handling), like a DocumentFragment.
  def _shadow_inner_html(server, node_id) do
    _atomic_ets_op(server, fn nodes, _index ->
      child_ids = Table.children_by_extent(nodes, node_id)
      IO.iodata_to_binary(DOM.HTML.children("", child_ids, nodes))
    end)
  end

  @doc false
  # Fragment-parse `html` in a default (div-like) context and replace the shadow
  # root's children with the result. Reuses the element innerHTML machinery.
  def _shadow_set_inner_html(server, node_id, html) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        root =
          fragment_root_for(
            html,
            %{name: "div", namespace: :html},
            nodes,
            index,
            Process.get(:document_id)
          )

        Enum.each(Table.children(nodes, node_id), &Table.remove_child(nodes, node_id, &1))
        Table.append_children(nodes, node_id, Table.children(nodes, root))
        resync_spans(nodes, index)
        # The shadow tree's <slot>s changed — reassign the host's light children.
        _recompute_slots(nodes, index, node_id)
        :ok
      end,
      :mutates
    )
  end

  @doc false
  def _shadow_host(%Node{server: server, node_id: node_id}) do
    _atomic_ets_op(server, fn nodes, _index ->
      host_id = Table.shadow_host(nodes, node_id)
      host_id && node_handle(nodes, host_id)
    end)
  end

  @doc false
  def _slot_assigned_nodes(server, slot_id) do
    _atomic_ets_op(server, fn nodes, index ->
      index
      |> DOM.NodeData.Slots.assigned_nodes(slot_id)
      |> Enum.map(&node_handle(nodes, &1))
    end)
  end

  @doc false
  # slot.assign: store `node_ids` as the slot's manual assignment (replacing any
  # prior), then recompute the host's slot assignment (manual mode uses these ids,
  # filtered to host children) and signal slotchange on the slots that changed.
  def _slot_assign(server, slot_id, node_ids) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        record = fetch_node!(nodes, slot_id)
        :ets.insert(nodes, {slot_id, %{record | manual_assigned: node_ids}})

        if host = Slots.host_of_slot(nodes, slot_id) do
          signal_slots(index, Slots.recompute(nodes, index, host))
        end

        :ok
      end,
      :mutates
    )
  end

  @doc false
  def _node_assigned_slot(server, node_id) do
    _atomic_ets_op(server, fn nodes, index ->
      case DOM.NodeData.Slots.assigned_slot(index, node_id) do
        nil -> nil
        slot_id -> node_handle(nodes, slot_id)
      end
    end)
  end

  @doc false
  def _node_get_root_node(server, node_id, composed?) do
    _atomic_ets_op(server, fn nodes, _index ->
      node_handle(nodes, root_node(nodes, node_id, composed?))
    end)
  end

  # Walk `parent` to the tree root. Non-composed stops there (a shadow root has
  # parent nil, so it IS the root). Composed jumps a shadow root to its host and
  # keeps walking, crossing every nested shadow boundary to the document.
  defp root_node(nodes, node_id, composed?) do
    case Table.parent(nodes, node_id) do
      nil -> maybe_cross_shadow(nodes, node_id, composed?)
      parent -> root_node(nodes, parent, composed?)
    end
  end

  defp maybe_cross_shadow(nodes, root_id, composed?) do
    host = composed? && Table.shadow_host(nodes, root_id)
    if host, do: root_node(nodes, host, composed?), else: root_id
  end

  @doc false
  # outerHTML setter (§): fragment-parse `html` in the element's PARENT context,
  # then replace the element itself (in the parent) with the parsed nodes. An
  # element with no element parent cannot be replaced.
  def _element_set_outer_html(server, node_id, html) do
    result =
      _atomic_ets_op(
        server,
        fn nodes, index ->
          parent_id = Table.parent(nodes, node_id)

          if is_nil(parent_id) or Table.type(nodes, parent_id) != :element do
            {:error, :no_modification}
          else
            parent = Table.fetch!(nodes, parent_id)
            context = %{name: parent.local_name, namespace: parent.namespace}
            root = fragment_root_for(html, context, nodes, index, Process.get(:document_id))

            Table.insert_children_before(nodes, parent_id, Table.children(nodes, root), node_id)
            Table.remove_child(nodes, parent_id, node_id)
            resync_spans(nodes, index)
            :ok
          end
        end,
        :mutates
      )

    case result do
      :ok -> :ok
      {:error, :no_modification} -> raise DOM.NoModificationAllowedError
    end
  end

  # Fragment-parse `html` in `context` into this document's table; return the
  # synthetic fragment-root id (whose children are the parsed nodes). build_into's
  # bulk-load indexes the parsed elements; span_index_all mirrors the fresh extents
  # into the span rows.
  defp fragment_root_for(html, context, nodes, index, document_id) do
    tokens = DOM.HTML.fragment_tokens(html, context.name)
    root = TreeBuilder.build_fragment_into(nodes, index, document_id, tokens, context)
    Table.span_index_all(nodes, index)
    root
  end

  def _element_outer_html(server, node_id) do
    _atomic_ets_op(server, fn nodes, _index ->
      IO.iodata_to_binary(DOM.HTML.serialize(fetch_node!(nodes, node_id), node_id, nodes))
    end)
  end

  defp get_elements_by_tag_name(nodes, index, node_id, name) do
    descendants = descendant_ids(nodes, node_id)

    ids =
      if name == "*" do
        # "*" wants every element descendant — the tag index gives no benefit, so
        # keep the element scan.
        Enum.filter(descendants, &element?(nodes, &1))
      else
        # A named tag is a point lookup in the tag index; keep tree order by
        # filtering the ordered descendant walk against the (scope-free) match set.
        matched = MapSet.new(Table.index_lookup(index, :tag, name))
        Enum.filter(descendants, &MapSet.member?(matched, &1))
      end

    Enum.map(ids, &node_handle(nodes, &1))
  end

  defp element?(nodes, node_id), do: match?(%NodeData.Element{}, fetch_node!(nodes, node_id))

  defp get_element_by_id(nodes, index, root_id, id) do
    # The index gives every node with this id doc-wide (unordered); intersect with
    # the scope root's descendants and return the first in tree order.
    matches = MapSet.new(Table.index_lookup(index, :id, id))

    match_id =
      if MapSet.size(matches) == 0 do
        nil
      else
        Enum.find(descendant_ids(nodes, root_id), &MapSet.member?(matches, &1))
      end

    if match_id, do: node_handle(nodes, match_id)
  end

  defp get_elements_by_class_name(nodes, index, root_id, names) do
    wanted = class_tokens(names)

    if wanted == [] do
      []
    else
      # Each token's index lookup yields all nodes carrying it doc-wide; intersect
      # those sets (an element must carry EVERY token), then filter to the scope
      # root's descendants in tree order.
      matched =
        wanted
        |> Enum.map(&MapSet.new(Table.index_lookup(index, :class, &1)))
        |> Enum.reduce(&MapSet.intersection/2)

      nodes
      |> descendant_ids(root_id)
      |> Enum.filter(&MapSet.member?(matched, &1))
      |> Enum.map(&node_handle(nodes, &1))
    end
  end

  # `selector` arrives already parsed and validated by the caller (parse_selector!).
  # In a `matches` context the node itself is the scoping root for `:scope`.
  defp matches?(nodes, index, node_id, selector) do
    # The scope for :host is the node's own shadow root's host, if the node is in a
    # shadow tree — matches(node, ":host") on a shadow host is true.
    scoped = DOM.CSS.bind_scope(selector, node_id)
    context = css_context(nodes, index, shadow_scope_host(nodes, node_id))

    Enum.any?(scoped, fn complex -> DOM.CSS.match(complex, context, [node_id]) != [] end)
  end

  # The tables a CSS match runs against (see DOM.CSS.context/0), plus the shadow
  # scope host (nil outside a shadow scope) for :host/:host-context/::slotted.
  defp css_context(nodes, index, scope_host) do
    %{nodes: nodes, index: index, scope_host: scope_host}
  end

  # The :host scope for matches(node): the node itself when it is a shadow host
  # (so `host.matches(":host")` is true), else the host of the shadow tree it lives
  # in, else nil.
  defp shadow_scope_host(nodes, node_id) do
    cond do
      Slots.shadow_host?(nodes, node_id) -> node_id
      host = Table.shadow_host(nodes, root_node(nodes, node_id, false)) -> host
      true -> nil
    end
  end

  # Descendant element ids of `root_id` matching `selector`, in tree order. Each
  # complex in the selector list contributes its matches; the union is ordered by
  # the tree-order descendant walk.
  # `selector` arrives already parsed and validated by the caller (parse_selector!).
  # `:scope` is bound to `root_id` so it can anchor relative matches (`:scope > p`)
  # via the combinator chain. Per querySelectorAll, the candidate result set is
  # the root's descendants only — the root itself is never returned, so a bare
  # `:scope` matches nothing (mirrors the browser).
  defp query_ids(root_id, selector, nodes, index) do
    scoped = DOM.CSS.bind_scope(selector, root_id)
    candidates = descendant_ids(nodes, root_id)

    # A shadow-scoped query's candidate set is exactly the shadow root's
    # descendants — the host and the slots' assigned (light-DOM) nodes are NOT
    # injected. querySelectorAll never returns them: `:host` and `::slotted(...)`
    # match nothing here (verified against Chromium+Firefox); `:host` is only
    # interrogable via matches/2, and `:host x` reaches the shadow tree through
    # the shadow-crossing combinator walk (Complex.related), not the candidate set.
    scope_host = shadow_query_host(nodes, root_id)
    context = css_context(nodes, index, scope_host)

    matched =
      scoped
      |> Enum.flat_map(fn complex -> DOM.CSS.match(complex, context, candidates) end)
      |> MapSet.new()

    Enum.filter(candidates, &MapSet.member?(matched, &1))
  end

  # The host of the query root, when the root is a shadow root; else nil. Sets the
  # :host-context scope for matches run inside a shadow-scoped query.
  defp shadow_query_host(nodes, root_id) do
    if Table.type(nodes, root_id) == :shadow_root, do: Table.shadow_host(nodes, root_id)
  end

  defp class_tokens(names), do: String.split(names)

  def _node_text_content(server, node_id) do
    _atomic_ets_op(server, fn nodes, _index ->
      nodes
      |> descendants(node_id)
      |> Enum.filter(&match?(%NodeData.Text{}, &1))
      |> Enum.map_join("", & &1.value)
    end)
  end

  # Replace all children with a single Text node (none when value is empty).
  def _node_set_text_content(server, node_id, value) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        nodes
        |> Table.children(node_id)
        |> Enum.each(&delete_subtree(nodes, index, &1))

        if value != "" do
          # append via the extent-authoritative mutator so the new text node is placed
          # (extent written), then mirrored into the span rows by resync.
          text_id = Table.create_text(nodes, value)
          Table.append_child(nodes, node_id, text_id)
        end

        resync_spans(nodes, index)
        :ok
      end,
      :mutates
    )
  end

  # Delete a subtree from the node table and retract each node's index + span +
  # listener rows (listeners do not survive removal, per the DOM).
  defp delete_subtree(nodes, index, node_id) do
    nodes
    |> subtree(node_id)
    |> Enum.each(fn {id, _node_data} ->
      Table.index_retract(index, id)
      Table.span_retract(index, id)
      Table.listeners_retract(index, id)
      :ets.delete(nodes, id)
    end)
  end

  def _node_set_value(server, node_id, value) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        node = fetch_node!(nodes, node_id)
        put_node(nodes, node_id, %{node | value: value})
        # characterData: the node's data changed; old_value is the prior value.
        queue_character_data_record(nodes, index, node_id, node.value)
        :ok
      end,
      :mutates
    )
  end

  @doc false
  # CharacterData replace-data: splice `data` in for `count` units at `offset`, then
  # adjust live Range boundaries in this node. `offset > length` raises IndexSizeError.
  def _char_data_replace(server, node_id, offset, count, data) do
    _atomic_ets_op(
      server,
      fn nodes, index ->
        node = fetch_node!(nodes, node_id)
        value = node.value
        len = String.length(value)
        if offset > len, do: raise(DOM.IndexSizeError)

        count = min(count, len - offset)

        new_value =
          String.slice(value, 0, offset) <> data <> String.slice(value, offset + count, len)

        put_node(nodes, node_id, %{node | value: new_value})

        DOM.Range.Adjust.on_replace_data(
          nodes,
          index,
          node.start,
          offset,
          count,
          String.length(data)
        )

        # characterData: data spliced; old_value is the whole prior value.
        queue_character_data_record(nodes, index, node_id, value)
        :ok
      end,
      :mutates
    )
  end

  @doc false
  # wholeText: concatenate the contiguous run of Text siblings including `node_id`.
  def _text_whole_text(server, node_id) do
    _atomic_ets_op(server, fn nodes, _index ->
      case Table.parent(nodes, node_id) do
        nil ->
          fetch_node!(nodes, node_id).value

        parent_id ->
          nodes
          |> Table.children(parent_id)
          |> contiguous_text_run(nodes, node_id)
          |> Enum.map_join("", &fetch_node!(nodes, &1).value)
      end
    end)
  end

  # The maximal run of adjacent :text children around `node_id` in `children`.
  defp contiguous_text_run(children, nodes, node_id) do
    text? = fn id -> Table.type(nodes, id) == :text end

    before =
      children
      |> Enum.take_while(&(&1 != node_id))
      |> Enum.reverse()
      |> Enum.take_while(text?)
      |> Enum.reverse()

    after_ = children |> Enum.drop_while(&(&1 != node_id)) |> Enum.take_while(text?)

    before ++ after_
  end

  # Descendant node_data in tree order, excluding the node itself.
  defp descendants(nodes, node_id) do
    nodes
    |> descendant_entries(node_id)
    |> Enum.map(fn {_id, node_data} -> node_data end)
  end

  # Descendant node ids in tree order, excluding the node itself.
  defp descendant_ids(nodes, node_id) do
    nodes
    |> descendant_entries(node_id)
    |> Enum.map(fn {id, _node_data} -> id end)
  end

  defp descendant_entries(nodes, node_id) do
    nodes
    |> Table.children(node_id)
    |> Enum.flat_map(&subtree(nodes, &1))
  end

  # ==========================================================================
  # Helper functions
  # ==========================================================================

  defp fetch_node!(nodes, node_id), do: Table.fetch!(nodes, node_id)

  defp put_node(nodes, node_id, node), do: Table.put(nodes, node_id, node)

  defp node_handle(nodes, node_id) do
    type = nodes |> fetch_node!(node_id) |> NodeData.type()
    %Node{server: self(), node_id: node_id, type: type}
  end

  defp subtree(nodes, node_id) do
    node_data = fetch_node!(nodes, node_id)

    [{node_id, node_data}] ++
      Enum.flat_map(Table.children(nodes, node_id), &subtree(nodes, &1))
  end

  # Structural equality: `a_id` (live in `nodes`) vs `b_id` (a snapshot map from a
  # possibly-other server). Compares the equality-relevant fields per kind, then
  # children pairwise in order.
  defp equal_node?(nodes, a_id, b_snapshot, b_id) do
    a = fetch_node!(nodes, a_id)
    b = Map.fetch!(b_snapshot, b_id)

    equal_fields?(a, b) and
      equal_children?(
        nodes,
        Table.children(nodes, a_id),
        b_snapshot,
        snapshot_children(b_snapshot, b_id)
      )
  end

  # The equality-relevant fields of a record, by struct kind (DOM "equals" §).
  # Mismatched kinds never share a clause, so they fall to the catch-all.
  defp equal_fields?(%NodeData.Element{} = a, %NodeData.Element{} = b) do
    a.namespace == b.namespace and a.local_name == b.local_name and
      Enum.sort(a.attributes) == Enum.sort(b.attributes)
  end

  defp equal_fields?(%NodeData.Text{value: v}, %NodeData.Text{value: v}), do: true
  defp equal_fields?(%NodeData.Comment{value: v}, %NodeData.Comment{value: v}), do: true

  defp equal_fields?(%NodeData.DocumentType{} = a, %NodeData.DocumentType{} = b) do
    a.name == b.name and a.public_id == b.public_id and a.system_id == b.system_id
  end

  # Document / DocumentFragment / ShadowRoot: no own fields (children compared
  # separately). Everything else — mismatched kinds, value mismatches — is unequal.
  defp equal_fields?(%mod{}, %mod{})
       when mod in [NodeData.Document, NodeData.DocumentFragment, NodeData.ShadowRoot],
       do: true

  defp equal_fields?(_a, _b), do: false

  defp equal_children?(nodes, a_children, b_snapshot, b_children) do
    length(a_children) == length(b_children) and
      a_children
      |> Enum.zip(b_children)
      |> Enum.all?(fn {ac, bc} -> equal_node?(nodes, ac, b_snapshot, bc) end)
  end

  # A snapshot record's child ids in document order (the snapshot is a flat id->rec
  # map from _export_subtree; reconstruct children from parent pointers + extents).
  defp snapshot_children(snapshot, parent_id) do
    snapshot
    |> Enum.filter(fn {_id, rec} -> Map.get(rec, :parent) == parent_id end)
    |> Enum.sort_by(fn {_id, rec} -> rec.start end)
    |> Enum.map(&elem(&1, 0))
  end

  # DOCUMENT_POSITION_* bitmask relating `other_id` to `node_id`, both in `nodes`.
  defp compare_document_position(_nodes, node_id, node_id), do: 0

  defp compare_document_position(nodes, node_id, other_id) do
    cond do
      # different trees (detached subtrees have distinct roots): DISCONNECTED (1) +
      # IMPLEMENTATION_SPECIFIC (32) + a stable direction (PRECEDING 2).
      tree_root_of(nodes, node_id) != tree_root_of(nodes, other_id) -> 1 + 32 + 2
      # other is contained by node: CONTAINED_BY (16) + FOLLOWING (4)
      other_id in Table.descendant_ids(nodes, node_id) -> 16 + 4
      # node is contained by other: CONTAINS (8) + PRECEDING (2)
      node_id in Table.descendant_ids(nodes, other_id) -> 8 + 2
      # otherwise pure document order via extent start keys
      doc_order_precedes?(nodes, node_id, other_id) -> 4
      true -> 2
    end
  end

  defp tree_root_of(nodes, node_id) do
    case Table.parent(nodes, node_id) do
      nil -> node_id
      parent_id -> tree_root_of(nodes, parent_id)
    end
  end

  defp doc_order_precedes?(nodes, a_id, b_id) do
    fetch_node!(nodes, a_id).start < fetch_node!(nodes, b_id).start
  end

  # ==========================================================================
  # Router
  # ==========================================================================

  @impl true
  def handle_continue({:parse, tokens}, state) do
    parse_impl(tokens, state)
  end

  def handle_continue({:fragment, {tokens, context}}, state) do
    fragment_impl(tokens, context, state)
  end

  def handle_continue(:drain_microtasks, state) do
    drain_microtasks_impl(state)
  end

  # An owner process monitored for a range died — the monitor ref is the range id.
  @impl true
  def handle_info({:DOWN, range_id, :process, _pid, _reason}, state) do
    range_cleanup_impl(range_id, state)
  end

  # A setTimeout timer fired — run it (a task) then run its microtask checkpoint.
  def handle_info({:run_timer, ref}, state) do
    run_timer_impl(ref, state)
  end

  @impl true
  def handle_call(:fragment_root, from, state) do
    fragment_root_impl(from, state)
  end

  @impl true
  def handle_call({:select_nodes, match_spec}, from, state) do
    select_nodes_impl(match_spec, from, state)
  end

  @impl true
  def handle_call({:select_index, match_spec}, from, state) do
    select_index_impl(match_spec, from, state)
  end

  @impl true
  def handle_call({:select_replace_nodes, match_spec}, from, state) do
    select_replace_nodes_impl(match_spec, from, state)
  end

  @impl true
  def handle_call({:select_replace_index, match_spec}, from, state) do
    select_replace_index_impl(match_spec, from, state)
  end

  @impl true
  def handle_call({:atomic_ets_op, op, mutates}, from, state) do
    atomic_ets_op_impl(op, mutates, from, state)
  end

  @impl true
  def handle_call({:enqueue_microtask, lambda}, from, state) do
    enqueue_microtask_impl(lambda, from, state)
  end

  @impl true
  def handle_call({:dispatch_event, node_id, event}, from, state) do
    dispatch_event_impl(node_id, event, from, state)
  end

  @impl true
  def handle_call({:lambda, fun}, from, state) do
    lambda_impl(fun, from, state)
  end

  @impl true
  def handle_call({:set_timer, kind, callback, delay}, from, state) do
    set_timer_impl(kind, callback, delay, from, state)
  end

  def handle_call(:check_index_consistency, from, state) do
    check_index_consistency_impl(from, state)
  end

  def handle_call({:range_create, document_id, owner}, from, state) do
    range_create_impl(document_id, owner, from, state)
  end

  def handle_call({:range_detach, range_id}, from, state) do
    range_detach_impl(range_id, from, state)
  end
end
