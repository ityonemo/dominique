defmodule DOM.NodeData.Table do
  @moduledoc """
  In-process operations over a document's nodes ETS table (`tid`) keyed by
  `node_id` (a `reference()`) — no GenServer, no `%DOM.Node{}` handles.

  This is the shared node/tree algorithm layer. The `DOM` GenServer's `*_impl`
  callbacks delegate here (so the public API and any in-process builder produce
  byte-identical trees), and the HTML tree builder calls these functions directly
  on the document's tid while parsing, avoiding a server round-trip per node.

  Records are the per-type `DOM.NodeData.*` structs stored as `{node_id, data}`;
  the adjacency is `parent`/`children` id pointers, so "moving" a node is a
  two-record edit (detach from the old parent, splice into the new) and its
  subtree follows for free. Reads go through the `DOM.NodeData` protocol.

  These functions assume SAME-DOCUMENT, hierarchy-valid operations (what the tree
  builder produces). The server's `*_impl` wraps them with the cross-document /
  hierarchy / fragment-flattening checks the public DOM API additionally needs.
  """

  use MatchSpec

  alias DOM.NodeData

  @type tid :: :ets.tid()
  @type id :: reference()

  # ==========================================================================
  # Low-level record access
  # ==========================================================================

  @doc "The `DOM.NodeData.*` record for `id` (raises if absent)."
  @spec fetch!(tid, id) :: struct()
  def fetch!(tid, id) do
    [{^id, data}] = :ets.lookup(tid, id)
    data
  end

  @doc "Write the record for `id`."
  @spec put(tid, id, struct()) :: :ok
  def put(tid, id, data) do
    true = :ets.insert(tid, {id, data})
    :ok
  end

  # ==========================================================================
  # Node creation (each mints a fresh id and inserts a detached record)
  # ==========================================================================

  @spec create_element(tid, String.t()) :: id
  def create_element(tid, local_name) do
    insert_new(tid, %NodeData.Element{local_name: local_name})
  end

  @spec create_element_ns(tid, String.t(), NodeData.Element.namespace(), [
          {String.t(), String.t()}
        ]) ::
          id
  def create_element_ns(tid, local_name, namespace, attributes) do
    insert_new(tid, %NodeData.Element{
      local_name: local_name,
      namespace: namespace,
      attributes: attributes
    })
  end

  @spec create_text(tid, String.t()) :: id
  def create_text(tid, value), do: insert_new(tid, %NodeData.Text{value: value})

  @spec create_comment(tid, String.t()) :: id
  def create_comment(tid, value), do: insert_new(tid, %NodeData.Comment{value: value})

  @spec create_doctype(tid, String.t(), String.t() | nil, String.t() | nil) :: id
  def create_doctype(tid, name, public_id, system_id) do
    insert_new(tid, %NodeData.DocumentType{name: name, public_id: public_id, system_id: system_id})
  end

  @spec create_document(tid) :: id
  def create_document(tid), do: insert_new(tid, %NodeData.Document{})

  @doc """
  Create a template element together with its "template contents" DocumentFragment,
  linked via the element's `content` field. Returns `{template_id, content_id}`.
  """
  @spec create_template(tid, [{String.t(), String.t()}]) :: {id, id}
  def create_template(tid, attributes) do
    content_id = insert_new(tid, %NodeData.DocumentFragment{})

    template_id =
      insert_new(tid, %NodeData.Element{
        local_name: "template",
        attributes: attributes,
        content: content_id
      })

    {template_id, content_id}
  end

  defp insert_new(tid, data) do
    id = make_ref()
    true = :ets.insert(tid, {id, data})
    id
  end

  # ==========================================================================
  # Mutation (same-document, hierarchy-valid moves)
  # ==========================================================================

  @doc """
  Append `child_id` to `parent_id`, detaching it from any current parent first
  (a move). The subtree rooted at `child_id` follows automatically.
  """
  @spec append_child(tid, id, id) :: :ok
  def append_child(tid, parent_id, child_id) do
    detach(tid, child_id)
    parent = fetch!(tid, parent_id)
    put(tid, parent_id, %{parent | children: parent.children ++ [child_id]})
    put(tid, child_id, %{fetch!(tid, child_id) | parent: parent_id})
  end

  @doc "Insert `child_id` immediately before `reference_id` under `parent_id`."
  @spec insert_before(tid, id, id, id) :: :ok
  def insert_before(tid, parent_id, child_id, reference_id) do
    detach(tid, child_id)
    parent = fetch!(tid, parent_id)
    {before, [reference | rest]} = Enum.split_while(parent.children, &(&1 != reference_id))
    put(tid, parent_id, %{parent | children: before ++ [child_id, reference | rest]})
    put(tid, child_id, %{fetch!(tid, child_id) | parent: parent_id})
  end

  @doc "Remove `child_id` from `parent_id` (child keeps its own subtree, parent nil)."
  @spec remove_child(tid, id, id) :: :ok
  def remove_child(tid, parent_id, child_id) do
    parent = fetch!(tid, parent_id)
    put(tid, parent_id, %{parent | children: List.delete(parent.children, child_id)})
    put(tid, child_id, %{fetch!(tid, child_id) | parent: nil})
  end

  @doc """
  Detach `id` from its current parent's child list (no-op when already detached).
  Only edits the parent — the node's own `parent` field is left as-is (the caller
  overwrites it on re-attach, or `remove_child` nils it).
  """
  @spec detach(tid, id) :: :ok
  def detach(tid, id) do
    child = fetch!(tid, id)

    if parent_id = child.parent do
      parent = fetch!(tid, parent_id)
      put(tid, parent_id, %{parent | children: List.delete(parent.children, id)})
    end

    :ok
  end

  # ==========================================================================
  # Reads (via the DOM.NodeData protocol / record fields)
  # ==========================================================================

  @spec type(tid, id) :: DOM.Node.type()
  def type(tid, id), do: tid |> fetch!(id) |> NodeData.type()

  @spec node_name(tid, id) :: String.t()
  def node_name(tid, id), do: tid |> fetch!(id) |> NodeData.node_name()

  @spec parent(tid, id) :: id | nil
  def parent(tid, id), do: tid |> fetch!(id) |> NodeData.parent()

  @spec children(tid, id) :: [id]
  def children(tid, id), do: tid |> fetch!(id) |> NodeData.children()

  @doc "A Text/Comment node's value."
  @spec value(tid, id) :: String.t()
  def value(tid, id), do: fetch!(tid, id).value

  @doc "Set a Text/Comment node's value (used for character coalescing)."
  @spec set_value(tid, id, String.t()) :: :ok
  def set_value(tid, id, value), do: put(tid, id, %{fetch!(tid, id) | value: value})

  # ==========================================================================
  # Element attributes / namespace
  # ==========================================================================

  @spec get_attribute(tid, id, String.t()) :: String.t() | nil
  def get_attribute(tid, id, name) do
    case List.keyfind(fetch!(tid, id).attributes, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  @spec has_attribute(tid, id, String.t()) :: boolean()
  def has_attribute(tid, id, name), do: List.keymember?(fetch!(tid, id).attributes, name, 0)

  @spec set_attribute(tid, id, String.t(), String.t()) :: :ok
  def set_attribute(tid, id, name, value) do
    element = fetch!(tid, id)

    put(tid, id, %{
      element
      | attributes: List.keystore(element.attributes, name, 0, {name, value})
    })
  end

  @doc "Set `name`=`value` only if the element does not already carry `name`."
  @spec put_attribute_if_absent(tid, id, String.t(), String.t()) :: :ok
  def put_attribute_if_absent(tid, id, name, value) do
    if has_attribute(tid, id, name), do: :ok, else: set_attribute(tid, id, name, value)
  end

  @spec namespace(tid, id) :: NodeData.Element.namespace() | nil
  def namespace(tid, id) do
    case fetch!(tid, id) do
      %NodeData.Element{namespace: namespace} -> namespace
      _ -> nil
    end
  end

  @doc "A template element's content DocumentFragment id, or nil."
  @spec content(tid, id) :: id | nil
  def content(tid, id) do
    case fetch!(tid, id) do
      %NodeData.Element{content: content} -> content
      _ -> nil
    end
  end

  # ==========================================================================
  # Deep/shallow clone and descendant queries
  # ==========================================================================

  @doc "Clone the node (deep when `deep?`) as a detached subtree; returns the new id."
  @spec clone(tid, id, boolean()) :: id
  def clone(tid, id, deep?) do
    data = fetch!(tid, id)
    clone_id = make_ref()

    children =
      if deep? do
        Enum.map(NodeData.children(data), fn child_id ->
          child_clone = clone(tid, child_id, true)
          put(tid, child_clone, %{fetch!(tid, child_clone) | parent: clone_id})
          child_clone
        end)
      else
        []
      end

    put(tid, clone_id, clone_data(data, children))
    clone_id
  end

  defp clone_data(%{children: _} = data, children), do: %{data | parent: nil, children: children}
  defp clone_data(data, _children), do: %{data | parent: nil}

  @doc "Descendant ids of `root_id` in tree (document) order — excludes `root_id`."
  @spec descendant_ids(tid, id) :: [id]
  def descendant_ids(tid, root_id) do
    tid
    |> fetch!(root_id)
    |> NodeData.children()
    |> Enum.flat_map(&subtree_ids(tid, &1))
  end

  @doc "Element descendant ids of `root_id` whose local name matches `name` (`*` = any)."
  @spec elements_by_tag_name(tid, id, String.t()) :: [id]
  def elements_by_tag_name(tid, root_id, name) do
    tid
    |> descendant_ids(root_id)
    |> Enum.filter(&tag_name_match?(tid, &1, name))
  end

  defp subtree_ids(tid, id) do
    [id | tid |> fetch!(id) |> NodeData.children() |> Enum.flat_map(&subtree_ids(tid, &1))]
  end

  defp tag_name_match?(tid, id, name) do
    case fetch!(tid, id) do
      %NodeData.Element{local_name: local_name} -> name == "*" or local_name == name
      _ -> false
    end
  end

  # ==========================================================================
  # Extent allocation (nested-set interval labeling)
  # ==========================================================================

  @doc """
    `interval(a, b)` allocates a fresh extent `{start, stop}` strictly between the
    binary order-keys `a < b`: `a < start < stop < b`, with the middle left
    subdividable (room for the node's own children) and room on each side for
    siblings. Keys grow by length-extension, never renumber.

    No guarantees are made about the distribution of the intervals, the algorithm
    is selected for quickness and ease.

    inputs: a and b must be binaries of at least one byte, and b must be greater
    than a. OUT OF CONTRACT: `a` must not be a proper prefix of `b` (e.g.
    `interval(<<5>>, <<5, 0>>)`). Real extent bounds are disjoint sibling gap keys
    (prev.stop, next.start), which are never in a prefix relationship, so this case
    never arises; the algorithm does not handle it and may return keys outside
    `(a, b)`.
  """
  @spec interval(binary(), binary()) :: {binary(), binary()}
  def interval(a, b), do: interval(a, b, [])

  @spec interval(binary, binary, iodata) :: {binary, binary}
  defp interval(<<a, rest1::binary>>, <<a, rest2::binary>>, so_far) do
    interval(rest1, rest2, [so_far, a])
  end

  defp interval(<<a, rest1::binary>>, <<b, _rest2::binary>>, so_far) do
    case b - a do
      1 ->
        interval(<<a, rest1::binary>>, <<a, 0xFF>>, so_far)

      2 ->
        build_interval(so_far, a + 1, <<a + 1, 0x80>>)

      delta ->
        # quartile formula is emperically proven over [0..255]
        build_interval(so_far, a + div(delta, 4) + 1, a + div(3 * delta, 4))
    end
  end

  # far corner cases, we don't want to check these on each iteration.
  defp interval(<<>>, b, so_far), do: interval(<<0>>, b, so_far)
  defp interval(any, <<>>, so_far), do: interval(any, <<0xFF>>, so_far)
  # we might exhaust if a is ...0xFFFF, and b is ...0x00 (gets subbed as 0xFF)
  defp interval(<<>>, <<>>, so_far), do: build_interval(so_far, [], 0x80)

  defp build_interval(so_far, a, b) do
    {IO.iodata_to_binary([so_far, a]), IO.iodata_to_binary([so_far, b])}
  end

  # ==========================================================================
  # Grafting (relocate an already-labeled subtree by prefix substitution)
  # ==========================================================================
  #
  # A subtree's node extents all share the byte-prefix of the subtree ROOT's own
  # window (they were carved inside `(root.start, root.stop)`). To relocate the
  # whole subtree into a destination gap `(gap_start, gap_stop)` we pick one anchor
  # key `P` strictly inside the gap and rewrite every node's key by swapping the
  # old shared prefix for `P` — preserving all RELATIVE ordering/containment, no
  # per-node `interval`. O(nodes moved).

  @doc """
  Relocate a labeled subtree into `(gap_start, gap_stop)`. `nodes` is the subtree's
  records (root first). `root_start`/`root_stop` are the subtree root's current
  extent (its shared-prefix window). Returns the records with `start`/`stop`
  prefix-remapped onto an anchor inside the gap. Callers overwrite `root` for a
  cross-document move.
  """
  @spec graft([map()], binary(), binary(), binary(), binary()) :: [map()]
  def graft(nodes, root_start, root_stop, gap_start, gap_stop) do
    anchor = common_bytewise_prefix(gap_start, gap_stop, [])
    prefix_len = common_prefix_len(root_start, root_stop, 0)
    Enum.map(nodes, &regraft_node(&1, anchor, prefix_len))
  end

  defp regraft_node(node, anchor, prefix_len) do
    %{
      node
      | start: reprefix(node.start, anchor, prefix_len),
        stop: reprefix(node.stop, anchor, prefix_len)
    }
  end

  # Swap the first `prefix_len` bytes of `key` for `anchor`.
  defp reprefix(key, anchor, prefix_len) do
    suffix = binary_part(key, prefix_len, byte_size(key) - prefix_len)
    IO.iodata_to_binary([anchor, suffix])
  end

  @doc """
  A single key strictly between the binary order-keys `start < stop` — the graft
  destination anchor. `anything > anchor` that shares `anchor` as a prefix is still
  `< stop`, so the whole relocated subtree fits under the gap's upper bound.
  """
  @spec common_bytewise_prefix(binary(), binary(), iodata()) :: binary()
  def common_bytewise_prefix(<<a, rest1::binary>>, <<a, rest2::binary>>, so_far) do
    common_bytewise_prefix(rest1, rest2, [so_far, a])
  end

  def common_bytewise_prefix(<<a, rest1::binary>>, <<b, _rest2::binary>>, so_far) do
    case b - a do
      1 ->
        # adjacent bytes: no midpoint — descend into `start`'s tail (length-extend).
        # 0xFF can't be the byte we increment: b would have wrapped, breaking a<b.
        IO.iodata_to_binary([so_far, a, remainder_prefix(rest1, [])])

      delta ->
        IO.iodata_to_binary([so_far, a + div(delta, 2)])
    end
  end

  # `start` exhausted while `stop` remains: treat the missing byte as 0 (mirrors
  # `interval`), so the anchor lands just above the accumulated prefix.
  def common_bytewise_prefix(<<>>, stop, so_far) do
    common_bytewise_prefix(<<0>>, stop, so_far)
  end

  defp remainder_prefix(<<>>, so_far), do: so_far
  defp remainder_prefix(<<255, rest::binary>>, so_far), do: remainder_prefix(rest, [so_far, 255])
  defp remainder_prefix(<<c, _rest::binary>>, so_far), do: [so_far, c + 1]

  @doc "Number of shared leading bytes of two keys."
  @spec common_prefix_len(binary(), binary(), non_neg_integer()) :: non_neg_integer()
  def common_prefix_len(<<a, rest1::binary>>, <<a, rest2::binary>>, count) do
    common_prefix_len(rest1, rest2, count + 1)
  end

  def common_prefix_len(_, _, count), do: count

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

  # Every membership an element contributes to the index, each a tuple headed by
  # its kind (the index row key appends a fresh ref):
  #   {:tag, local_name} | {:id, value} | {:class, token} | {:attr, name, value}
  # Every attribute yields an {:attr, …} membership (id/class included), so their
  # attribute-selector forms are index-backed too, alongside the dedicated
  # {:id,…}/{:class,…} memberships. Single source of truth for index_put and the
  # consistency checker.
  defp memberships(%NodeData.Element{local_name: local_name, attributes: attributes}) do
    ids = for {"id", value} <- attributes, do: {:id, value}

    classes =
      for {"class", value} <- attributes, token <- class_tokens(value), do: {:class, token}

    attrs = for {name, value} <- attributes, do: {:attr, name, value}
    [{:tag, local_name} | ids ++ classes ++ attrs]
  end

  # A class attribute's distinct whitespace-separated tokens (classList is a set,
  # so `class="x x"` yields one `x`). Mirrored in check_consistency!.
  defp class_tokens(value), do: value |> String.split() |> Enum.uniq()

  @doc """
  Populate `index` from every element row in `nodes` — the bulk path used once a
  subtree is built directly into the node table (e.g. after HTML parsing, where
  the tree builder writes only the node table). Assumes the relevant index rows
  are not already present.
  """
  @spec reindex(tid, tid) :: :ok
  def reindex(nodes, index) do
    for {node_id, %NodeData.Element{} = element} <- :ets.tab2list(nodes) do
      index_put(index, node_id, element)
    end

    :ok
  end

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

  @doc "Write the two span rows (`:start`/`:stop`) for `node_id`'s extent."
  @spec span_put(tid, id, %{root: id, parent: id | nil, start: binary(), stop: binary()}) :: :ok
  def span_put(index, node_id, %{root: root, parent: parent, start: start, stop: stop}) do
    :ets.insert(index, {{:span, root, start, :start, parent}, node_id})
    :ets.insert(index, {{:span, root, stop, :stop, parent}, node_id})
    :ok
  end

  @doc "Delete `node_id`'s span rows (matched by node id, so extent need not be known)."
  @spec span_retract(tid, id) :: :ok
  def span_retract(index, node_id) do
    :ets.match_delete(index, {{:span, :_, :_, :_, :_}, node_id})
    :ok
  end

  @doc """
  The ordered child ids of `parent_id` within tree `root`, read from the span
  rows: the `:start` rows whose key falls strictly inside `(pstart, pstop)` and
  whose parent is `parent_id`, in `start` order. A bounded range scan.
  """
  @spec span_children(tid, id, id, binary(), binary()) :: [id]
  def span_children(index, root, parent_id, pstart, pstop) do
    :ets.select(index, span_children_spec(root, parent_id, pstart, pstop))
  end

  defmatchspecp span_children_spec(root, parent_id, pstart, pstop) do
    {{:span, ^root, s, :start, ^parent_id}, node_id} when s > pstart and s < pstop -> node_id
  end

  # Every span row as `{root, key, kind, parent, node_id}` — used by the checker.
  @spec span_rows(tid) :: [{id, binary(), :start | :stop, id | nil, id}]
  defp span_rows(index) do
    :ets.select(index, span_rows_spec())
  end

  defmatchspecp span_rows_spec() do
    {{:span, root, key, kind, parent}, node_id} -> {root, key, kind, parent, node_id}
  end

  @doc "Ordered child ids of `node_id`, read from its record's extent + span rows."
  @spec span_children_of(tid, tid, id) :: [id]
  def span_children_of(nodes, index, node_id) do
    node = fetch!(nodes, node_id)
    span_children(index, ns_root(node, node_id), node_id, node.start, node.stop)
  end

  # ==========================================================================
  # Span construction (bulk carve) and grafting (relocation) over the ETS tables
  # ==========================================================================

  @doc """
  (Re)build span rows + record extents for EVERY tree root (`parent == nil`) from
  the current `children` field — the bulk allocator run at the post-parse/clone
  seam. Multi-root: the document, template `content` fragments, fragment/clone
  roots all appear. O(n).
  """
  @spec span_build_all(tid, tid) :: :ok
  def span_build_all(nodes, index) do
    for {id, data} <- :ets.tab2list(nodes), NodeData.parent(data) == nil do
      span_build(nodes, index, id)
    end

    :ok
  end

  @doc """
  Carve `root_id`'s subtree (from the `children` field) into fresh extents rooted
  at the fixed `<<0x00>>..<<0x80>>` window, writing each record's `root/start/stop`
  and its span rows. Retracts the subtree's old spans first.
  """
  @spec span_build(tid, tid, id) :: :ok
  def span_build(nodes, index, root_id) do
    Enum.each(subtree_ids(nodes, root_id), &span_retract(index, &1))
    span_carve(nodes, index, root_id, root_id, nil, <<0x00>>, <<0x80>>)
    :ok
  end

  # Assign `id` the extent `(start, stop)` under `parent` in tree `root`, write its
  # span rows, then carve its children left-to-right within `(start, stop)`.
  defp span_carve(nodes, index, id, root, parent, start, stop) do
    put(nodes, id, %{fetch!(nodes, id) | root: root, parent: parent, start: start, stop: stop})
    span_put(index, id, %{root: root, parent: parent, start: start, stop: stop})

    fetch!(nodes, id)
    |> NodeData.children()
    |> Enum.reduce(start, fn child, prev ->
      {cstart, cstop} = interval(prev, stop)
      span_carve(nodes, index, child, root, id, cstart, cstop)
      cstop
    end)
  end

  @doc """
  Relocate an already-labeled subtree (root `subtree_id`, currently detached in the
  `children` field under `new_parent_id`) into `new_parent_id`'s child order via
  grafting: prefix-remap every subtree node's extent onto an anchor in the
  destination gap, rewriting records + span rows (delete-old + insert-new, since the
  extent is in the span key). The subtree's new `root` becomes `new_parent`'s root.
  """
  @spec span_graft(tid, tid, id, id) :: :ok
  def span_graft(nodes, index, subtree_id, new_parent_id) do
    parent = fetch!(nodes, new_parent_id)
    proot = ns_root(parent, new_parent_id)
    old = fetch!(nodes, subtree_id)
    {gap_a, gap_b} = child_gap(nodes, index, new_parent_id, parent, proot, subtree_id)

    ids = subtree_ids(nodes, subtree_id)
    recs = Enum.map(ids, &fetch!(nodes, &1))
    grafted = graft(recs, old.start, old.stop, gap_a, gap_b)

    Enum.zip(ids, grafted)
    |> Enum.each(fn {id, rec} ->
      span_retract(index, id)
      new = %{fetch!(nodes, id) | root: proot, start: rec.start, stop: rec.stop}
      put(nodes, id, new)
      span_put(index, id, %{root: proot, parent: new.parent, start: rec.start, stop: rec.stop})
    end)

    :ok
  end

  # The (a, b) bounds for placing `child_id` among `parent`'s current children (in
  # the field), skipping `child_id` itself: gap between the sibling before it and
  # the sibling after it (or the parent's own start/stop at the ends).
  defp child_gap(nodes, _index, _parent_id, parent, _proot, child_id) do
    kids = NodeData.children(parent)
    {before, after_} = Enum.split_while(kids, &(&1 != child_id))
    after_ = tl(after_)
    a = if prev = List.last(before), do: fetch!(nodes, prev).stop, else: parent.start
    b = if next = List.first(after_), do: fetch!(nodes, next).start, else: parent.stop
    {a, b}
  end

  # ==========================================================================
  # Consistency checking
  # ==========================================================================

  @doc """
  Assert the document's ETS invariants, returning `:ok` or raising:

    * **adjacency integrity** — `parent`/`children` pointers agree bidirectionally
      (see below);
    * **id index agreement** (when an `index` tid is given) — the id index exactly
      mirrors the id attributes of every element row.

  Adjacency, for every node: each child in `children` appears exactly once and
  points back (`child.parent == node`); and every node whose non-nil `parent` is
  `node` appears in `node`'s `children`. A legitimately detached subtree (its
  root's `parent` is `nil`, internal edges agreeing) passes; a `detach`-and-forgot
  leak or a dangling pointer fails. Meant to run between operations (e.g. an
  `on_exit` hook), never mid-operation.
  """
  @spec check_consistency!(tid) :: :ok
  @spec check_consistency!(tid, tid) :: :ok
  def check_consistency!(tid, index \\ nil) do
    rows = :ets.tab2list(tid)
    parents = Map.new(rows, fn {id, data} -> {id, NodeData.parent(data)} end)

    Enum.each(rows, fn {id, data} ->
      children = NodeData.children(data)
      check_no_duplicate_children!(id, children)
      check_children_point_back!(id, children, parents)
    end)

    check_parents_are_listed!(rows)

    if index do
      check_index!(rows, index)
      check_spans!(rows, index)
    end

    :ok
  end

  # Span (extent) consistency, three ways:
  #   * backward — every id referenced by a span row exists as a node row;
  #   * forward  — walking each root's tree, each child's extent is contained in
  #     its parent's and children are in start-key order;
  #   * agreement — the span-derived ordered children equal the record `children`
  #     field (the dual-write invariant, until the field is removed).
  # Only runs once the tree has been extent-labeled (any node carries a `start`);
  # before that (pure pre-migration trees) there are no span rows to check.
  defp check_spans!(rows, index) do
    node_ids = MapSet.new(rows, fn {id, _data} -> id end)
    spans = span_rows(index)

    if spans != [] do
      check_spans_backward!(spans, node_ids)
      by_id = Map.new(rows)
      Enum.each(rows, fn {id, data} -> check_node_spans!(id, data, by_id, index) end)
    end
  end

  # backward: no span row points at a node that isn't in the table.
  defp check_spans_backward!(spans, node_ids) do
    Enum.each(spans, fn {_root, _key, _kind, parent, node_id} ->
      unless MapSet.member?(node_ids, node_id) do
        raise "dangling span: node #{inspect(node_id)} not in the nodes table"
      end

      if parent != nil and not MapSet.member?(node_ids, parent) do
        raise "dangling span: parent #{inspect(parent)} not in the nodes table"
      end
    end)
  end

  # forward + agreement, for one node's children.
  defp check_node_spans!(id, data, by_id, index) do
    {root, start, stop} = {ns_root(data, id), ns_start(data), ns_stop(data)}
    span_kids = span_children(index, root, id, start, stop)

    # agreement: span-derived children == the record children field (same order).
    field_kids = NodeData.children(data)

    if span_kids != field_kids do
      raise "span/children disagree for #{inspect(id)}: " <>
              "spans #{inspect(span_kids)} vs field #{inspect(field_kids)}"
    end

    # forward containment: each child's extent strictly inside this node's.
    Enum.each(span_kids, fn kid ->
      k = Map.fetch!(by_id, kid)

      unless start < ns_start(k) and ns_start(k) < ns_stop(k) and ns_stop(k) < stop do
        raise "extent containment violated: child #{inspect(kid)} " <>
                "#{inspect({ns_start(k), ns_stop(k)})} not inside " <>
                "#{inspect(id)} #{inspect({start, stop})}"
      end
    end)
  end

  # A root node (parent nil) is its own tree root; else read the stored root.
  defp ns_root(data, id), do: Map.get(data, :root) || id
  defp ns_start(data), do: Map.fetch!(data, :start)
  defp ns_stop(data), do: Map.fetch!(data, :stop)

  # The index must equal, as a sorted list of {membership, node} pairs, the
  # memberships (tag/id/class/attr) of the element rows — no missing, stale,
  # duplicate, or dangling row. A `membership` is the row key with its trailing
  # ref dropped, so this is arity-agnostic across the kinds.
  defp check_index!(rows, index) do
    expected =
      for {node_id, %NodeData.Element{} = element} <- rows,
          membership <- memberships(element),
          do: {membership, node_id}

    # Only membership rows (tag/id/class/attr); span rows are a separate concern.
    actual =
      for {key, node_id} <- :ets.tab2list(index),
          elem(key, 0) in [:tag, :id, :class, :attr],
          do: {drop_ref(key), node_id}

    if Enum.sort(expected) != Enum.sort(actual) do
      raise "inconsistent index: expected #{inspect(Enum.sort(expected))}, " <>
              "got #{inspect(Enum.sort(actual))}"
    end
  end

  # An index row key minus its trailing membership ref (its {kind, value…} head).
  defp drop_ref(key) do
    key |> Tuple.to_list() |> Enum.drop(-1) |> List.to_tuple()
  end

  defp check_no_duplicate_children!(id, children) do
    if children != Enum.uniq(children) do
      raise "inconsistent tree: #{inspect(id)} lists a child more than once"
    end
  end

  defp check_children_point_back!(id, children, parents) do
    Enum.each(children, fn child_id ->
      if Map.get(parents, child_id) != id do
        raise "inconsistent tree: #{inspect(id)} lists child #{inspect(child_id)}, " <>
                "but the child's parent is #{inspect(Map.get(parents, child_id))}"
      end
    end)
  end

  defp check_parents_are_listed!(rows) do
    children_of = Map.new(rows, fn {id, data} -> {id, NodeData.children(data)} end)

    Enum.each(rows, fn {id, data} ->
      parent_id = NodeData.parent(data)

      if parent_id != nil and id not in Map.get(children_of, parent_id, []) do
        raise "inconsistent tree: #{inspect(id)} has parent #{inspect(parent_id)}, " <>
                "but that parent does not list it as a child"
      end
    end)
  end
end
