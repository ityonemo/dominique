defmodule DOM.NodeData.Table do
  @moduledoc """
  In-process operations over a document's nodes ETS table (`tid`) keyed by
  `node_id` (a `reference()`) — no GenServer, no `%DOM.Node{}` handles.

  This is the shared node/tree algorithm layer. The `DOM` GenServer's `*_impl`
  callbacks delegate here (so the public API and any in-process builder produce
  byte-identical trees), and the HTML tree builder calls these functions directly
  on the document's tid while parsing, avoiding a server round-trip per node.

  Records are the per-type `DOM.NodeData.*` structs stored as `{node_id, data}`.
  Adjacency is nested-set: each node carries a `parent` pointer and a `{root,
  start, stop}` extent (binary order-keys); a node's ordered children are the rows
  whose `parent` is it, read by `start` key (`children_by_extent/2`). "Moving" a
  node re-labels its subtree's extents (a fresh `interval` for a new node, a
  `graft` for an existing subtree). The index tid mirrors the extents as span rows
  for O(log n + m) range reads.

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

  Extent-authoritative: assigns `child_id` a fresh extent in the gap after
  `parent_id`'s last child (a fresh node via `interval`, an already-labeled
  subtree via `graft`), so the adjacency is readable by extent order (see
  `children_by_extent/2`) with no separate carve pass.
  """
  @spec append_child(tid, id, id) :: :ok
  def append_child(tid, parent_id, child_id) do
    detach(tid, child_id)
    parent = ensure_extent(tid, parent_id)
    place_child(tid, parent_id, child_id, extent_after_last(tid, parent_id, parent))
    put(tid, child_id, %{fetch!(tid, child_id) | parent: parent_id})
  end

  @doc "Insert `child_id` immediately before `reference_id` under `parent_id`."
  @spec insert_before(tid, id, id, id) :: :ok
  def insert_before(tid, parent_id, child_id, reference_id) do
    detach(tid, child_id)
    parent = ensure_extent(tid, parent_id)
    place_child(tid, parent_id, child_id, extent_before(tid, parent_id, parent, reference_id))
    put(tid, child_id, %{fetch!(tid, child_id) | parent: parent_id})
  end

  @doc """
  Append `child_ids` (in order) to `parent_id` in one shot: carve the whole
  append gap into N windows with a single `multispan/3` (one `interval/2` for a
  lone child) and place each child into its window. Equivalent to N
  `append_child/3` calls but with one extent partition instead of N successive
  ones. Each child is detached from any current parent first.
  """
  @spec append_children(tid, id, [id]) :: :ok
  def append_children(_tid, _parent_id, []), do: :ok

  def append_children(tid, parent_id, child_ids) do
    Enum.each(child_ids, &detach(tid, &1))
    parent = ensure_extent(tid, parent_id)
    {gap_a, gap_b} = extent_after_last(tid, parent_id, parent)
    place_children(tid, parent_id, child_ids, gap_a, gap_b)
  end

  @doc """
  Insert `child_ids` (in order) immediately before `reference_id` under
  `parent_id`, carving the single gap `(prev_sibling.stop || parent.start,
  reference.start)` into N windows with one `multispan/3`.
  """
  @spec insert_children_before(tid, id, [id], id) :: :ok
  def insert_children_before(_tid, _parent_id, [], _reference_id), do: :ok

  def insert_children_before(tid, parent_id, child_ids, reference_id) do
    Enum.each(child_ids, &detach(tid, &1))
    parent = ensure_extent(tid, parent_id)
    {gap_a, gap_b} = extent_before(tid, parent_id, parent, reference_id)
    place_children(tid, parent_id, child_ids, gap_a, gap_b)
  end

  # Partition `(gap_a, gap_b)` into one window per child (multispan; interval for a
  # lone child) and place each child at its window: a fresh node takes the window as
  # its extent directly; an already-labeled subtree is grafted into it (window as
  # the destination gap). Then link the child's parent pointer.
  defp place_children(tid, parent_id, child_ids, gap_a, gap_b) do
    root = ns_root(fetch!(tid, parent_id), parent_id)

    child_ids
    |> carve_windows(gap_a, gap_b)
    |> Enum.each(fn {child_id, {wstart, wstop}} ->
      child = fetch!(tid, child_id)

      if child.start == nil do
        put(tid, child_id, %{child | root: root, start: wstart, stop: wstop, parent: parent_id})
      else
        graft_subtree(tid, child_id, child, root, wstart, wstop)
        put(tid, child_id, %{fetch!(tid, child_id) | parent: parent_id})
      end
    end)
  end

  # Pair each child id with its extent window: none for [], a single interval for
  # one child, a multispan partition for many.
  defp carve_windows([], _a, _b), do: []
  defp carve_windows([only], a, b), do: [{only, interval(a, b)}]
  defp carve_windows(ids, a, b), do: Enum.zip(ids, multispan(a, b, length(ids)))

  @doc "Remove `child_id` from `parent_id` (child keeps its own subtree, re-rooted at it)."
  @spec remove_child(tid, id, id) :: :ok
  def remove_child(tid, _parent_id, child_id), do: detach(tid, child_id)

  # Give `child_id` an extent in the `(gap_a, gap_b)` gap under `parent_id`'s tree,
  # writing its `root`/`start`/`stop`. A fresh child (no extent yet) gets a single
  # `interval`; an already-labeled subtree is relocated wholesale by `graft` (its
  # descendants' relative keys preserved, `root` rewritten to the new tree).
  defp place_child(tid, parent_id, child_id, {gap_a, gap_b}) do
    root = ns_root(fetch!(tid, parent_id), parent_id)
    child = fetch!(tid, child_id)

    if child.start == nil do
      {start, stop} = interval(gap_a, gap_b)
      put(tid, child_id, %{child | root: root, start: start, stop: stop})
    else
      graft_subtree(tid, child_id, child, root, gap_a, gap_b)
    end
  end

  # Relocate the already-labeled subtree rooted at `child_id` into `(gap_a, gap_b)`,
  # rewriting every subtree node's extent (prefix-remap) and its `root`.
  defp graft_subtree(tid, child_id, child, root, gap_a, gap_b) do
    ids = subtree_ids(tid, child_id)
    recs = Enum.map(ids, &fetch!(tid, &1))
    grafted = graft(recs, child.start, child.stop, gap_a, gap_b)

    Enum.zip(ids, grafted)
    |> Enum.each(fn {id, rec} ->
      put(tid, id, %{fetch!(tid, id) | root: root, start: rec.start, stop: rec.stop})
    end)
  end

  # Ensure `id` carries an extent: a tree root (parent nil) with no extent yet is
  # seeded with the fixed root window `<<0x00>>..<<0x80>>` (the tree-root extent).
  # Returns the (possibly updated) record.
  defp ensure_extent(tid, id) do
    case fetch!(tid, id) do
      %{start: nil} = data ->
        seeded = %{data | root: id, start: <<0x00>>, stop: <<0x80>>}
        put(tid, id, seeded)
        seeded

      data ->
        data
    end
  end

  # The gap after `parent`'s current last child: (last_child.stop, parent.stop), or
  # (parent.start, parent.stop) when empty. Order comes from the record extents.
  defp extent_after_last(tid, parent_id, parent_data) do
    a =
      case List.last(children_by_extent(tid, parent_id)) do
        nil -> parent_data.start
        last -> fetch!(tid, last).stop
      end

    {a, parent_data.stop}
  end

  # The gap for a node inserted before `reference_id`: (prev_sibling.stop ||
  # parent.start, reference.start), with the previous sibling found by extent order.
  defp extent_before(tid, parent_id, parent_data, reference_id) do
    before =
      tid
      |> children_by_extent(parent_id)
      |> Enum.take_while(&(&1 != reference_id))

    a = if prev = List.last(before), do: fetch!(tid, prev).stop, else: parent_data.start
    {a, fetch!(tid, reference_id).start}
  end

  @doc """
  Detach `id` from its current parent (no-op when already detached). `id`'s `parent`
  is nilled and its subtree is RE-ROOTED at `id` (its own `.root` -> nil = itself, its
  descendants' `.root` -> `id`) so the `.root`/extent bookkeeping stays truthful to the
  parent topology — the consistency net asserts `.root` == the walked parent root. The
  caller overwrites `parent`/`root` again on re-attach (via `place_child`/`graft`).
  """
  @spec detach(tid, id) :: :ok
  def detach(tid, id) do
    put(tid, id, %{fetch!(tid, id) | parent: nil, root: nil})
    reroot_descendants(tid, id)
    :ok
  end

  # Point every descendant of `id`'s `.root` at `id` (its new tree root). `id` itself
  # keeps `root: nil` (a tree root; ns_root resolves it to itself).
  defp reroot_descendants(tid, id) do
    for descendant <- descendant_ids(tid, id) do
      put(tid, descendant, %{fetch!(tid, descendant) | root: id})
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
  def children(tid, id), do: children_by_extent(tid, id)

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
    case Enum.find(fetch!(tid, id).attributes, fn {key, _v} ->
           NodeData.Element.matches_key?(key, name)
         end) do
      {_key, value} -> value
      nil -> nil
    end
  end

  @spec has_attribute(tid, id, String.t()) :: boolean()
  def has_attribute(tid, id, name) do
    Enum.any?(fetch!(tid, id).attributes, fn {key, _v} ->
      NodeData.Element.matches_key?(key, name)
    end)
  end

  @spec set_attribute(tid, id, String.t(), String.t()) :: :ok
  def set_attribute(tid, id, name, value) do
    element = fetch!(tid, id)
    put(tid, id, %{element | attributes: put_attr_by_name(element.attributes, name, value)})
  end

  # Update the value of the attribute matching qualified `name` (key preserved), or
  # append a plain-keyed attribute when none matches.
  defp put_attr_by_name(attrs, name, value) do
    if Enum.any?(attrs, fn {key, _v} -> NodeData.Element.matches_key?(key, name) end) do
      Enum.map(attrs, &update_attr_value(&1, name, value))
    else
      attrs ++ [{name, value}]
    end
  end

  defp update_attr_value({key, _v} = attr, name, value) do
    if NodeData.Element.matches_key?(key, name), do: {key, value}, else: attr
  end

  @doc "Set `name`=`value` only if the element does not already carry `name`."
  @spec put_attribute_if_absent(tid, id, String.t(), String.t()) :: :ok
  def put_attribute_if_absent(tid, id, name, value) do
    if has_attribute(tid, id, name), do: :ok, else: set_attribute(tid, id, name, value)
  end

  @doc "Remove the attribute matching qualified `name` (a no-op when absent)."
  @spec remove_attribute(tid, id, String.t()) :: :ok
  def remove_attribute(tid, id, name) do
    element = fetch!(tid, id)

    kept =
      Enum.reject(element.attributes, fn {key, _v} -> NodeData.Element.matches_key?(key, name) end)

    put(tid, id, %{element | attributes: kept})
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

  @doc """
  Attach a shadow root to `host_id`: create a detached `ShadowRoot` record (its
  own root; `ensure_extent` seeds its window on first append, like template
  content) and back-link it on the host element. Returns the shadow root id.
  """
  @spec create_shadow_root(tid, id, :open | :closed, :named | :manual) :: id
  def create_shadow_root(tid, host_id, mode, slot_assignment \\ :named) do
    shadow_id =
      insert_new(tid, %NodeData.ShadowRoot{
        host: host_id,
        mode: mode,
        slot_assignment: slot_assignment
      })

    host = fetch!(tid, host_id)
    put(tid, host_id, %{host | shadow_root: shadow_id})
    shadow_id
  end

  @doc "An element's shadow root id, or nil."
  @spec shadow_root(tid, id) :: id | nil
  def shadow_root(tid, id) do
    case fetch!(tid, id) do
      %NodeData.Element{shadow_root: shadow_root} -> shadow_root
      _ -> nil
    end
  end

  @doc "A shadow root's host element id, or nil."
  @spec shadow_host(tid, id) :: id | nil
  def shadow_host(tid, id) do
    case fetch!(tid, id) do
      %NodeData.ShadowRoot{host: host} -> host
      _ -> nil
    end
  end

  @doc "A shadow root's mode (`:open`/`:closed`), or nil for a non-shadow-root."
  @spec shadow_mode(tid, id) :: :open | :closed | nil
  def shadow_mode(tid, id) do
    case fetch!(tid, id) do
      %NodeData.ShadowRoot{mode: mode} -> mode
      _ -> nil
    end
  end

  # ==========================================================================
  # Deep/shallow clone and descendant queries
  # ==========================================================================

  @doc """
  Clone the node (deep when `deep?`) as a detached subtree; returns the new id.
  The clone is a fully extent-labeled tree in its own right (root window
  `<<0x00>>..<<0x80>>`, descendants carved inside from the SOURCE's extent order),
  so appending it later grafts the whole subtree.
  """
  @spec clone(tid, id, boolean()) :: id
  def clone(tid, id, deep?) do
    clone_id = make_ref()
    clone_subtree(tid, id, deep?, clone_id, clone_id, nil, <<0x00>>, <<0x80>>)
    clone_id
  end

  # Copy `src_id`'s record onto `clone_id` with the given extent (tree `root`,
  # `parent`), then (deep) clone its source children in extent order, carving each
  # into a fresh sub-interval. Single pass: order from the source's extents,
  # adjacency from parent pointers — no `children` field.
  defp clone_subtree(tid, src_id, deep?, clone_id, root, parent, start, stop) do
    put(tid, clone_id, %{
      fetch!(tid, src_id)
      | parent: parent,
        root: root,
        start: start,
        stop: stop
    })

    if deep? do
      tid
      |> children_by_extent(src_id)
      |> Enum.reduce(start, fn src_child, prev ->
        {cstart, cstop} = interval(prev, stop)
        clone_subtree(tid, src_child, true, make_ref(), root, clone_id, cstart, cstop)
        cstop
      end)
    end
  end

  @doc "Descendant ids of `root_id` in tree (document) order — excludes `root_id`."
  @spec descendant_ids(tid, id) :: [id]
  def descendant_ids(tid, root_id) do
    tid
    |> children_by_extent(root_id)
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
    [id | tid |> children_by_extent(id) |> Enum.flat_map(&subtree_ids(tid, &1))]
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
    {build_key([so_far, a]), build_key([so_far, b])}
  end

  # The one place order-keys are materialized: flatten accumulated prefix iodata
  # (shared-prefix bytes, an appended byte, a remapped suffix, …) into a binary key.
  # Used across interval / multispan / graft / common-prefix.
  defp build_key(iodata), do: IO.iodata_to_binary(iodata)

  @doc """
  `multispan(a, b, count)` allocates `count` fresh extents `[{s1,e1}, …]` in one
  pass, all strictly inside `a < b` and mutually ordered/disjoint with room
  between them: `a < s1 < e1 < s2 < … < e_count < b`. The batch analog of
  `interval/2` (`multispan(a, b, 1)` ≈ `interval(a, b)`), for bulk-loading a whole
  child list into a parent's window at once.

  Same input contract as `interval/2`: `a`, `b` non-empty binaries with `a < b`,
  `a` not a proper prefix of `b`. `count >= 1`.
  """
  @spec multispan(binary(), binary(), pos_integer()) :: [{binary(), binary()}]
  def multispan(a, b, count), do: multispan(a, b, count, [])

  @spec multispan(binary(), binary(), pos_integer(), iodata()) :: [{binary(), binary()}]
  defp multispan(<<a, rest1::binary>>, <<b, rest2::binary>>, count, so_far) do
    case b - a - 2 do
      -2 ->
        # a == b: shared byte, descend accumulating it into the prefix.
        multispan(rest1, rest2, count, [so_far, a])

      -1 ->
        # a + 1 == b: adjacent bytes, no interior value between them. Length-extend
        # under `a` (mirroring interval/2's delta-1 descent): keep the shared byte
        # `a` and carve into its tail below 0xFF — all of `(a.rest1, a.0xFF)` sits
        # below `b`, so the whole batch stays under the upper bound.
        multispan(rest1, <<0xFF>>, count, [so_far, a])

      delta when delta > count * 2 ->
        # roomy: `count` windows fit at this byte. Stride 2*interval per window
        # (gap, window, gap, window, …); interval = usable span / (2*count).
        interval = div(delta, 2 * count)
        build_multispan_safe(so_far, a, count, interval)

      _too_tight ->
        # can't fit `count` windows at this byte. Spread them across the interior
        # bytes `a+1 … b-1` (there are `b - a - 1` of them), recursing under each to
        # length-extend, over-provisioning per byte, trimming to exactly `count`.
        interior = b - a - 1
        per_nextbyte = div(count, interior) + 1

        {windows, _left} =
          Enum.flat_map_reduce(1..interior, count, fn offset, left ->
            multispan_under_byte(rest1, [so_far, a + offset], per_nextbyte, left)
          end)

        windows
    end
  end

  # far corners, mirroring interval/2's empty-bound clamps.
  defp multispan(<<>>, b, count, so_far), do: multispan(<<0>>, b, count, so_far)
  defp multispan(any, <<>>, count, so_far), do: multispan(any, <<0xFF>>, count, so_far)

  # One interior byte's share during the too-tight spread: place up to `per_byte`
  # windows (but no more than `left` still owed) under `prefix`'s tail, or nothing
  # once the quota is met. Returns the flat_map_reduce `{windows, remaining}` pair.
  defp multispan_under_byte(_rest, _prefix, _per_byte, left) when left <= 0, do: {[], left}

  defp multispan_under_byte(rest, prefix, per_byte, left) do
    got = multispan(rest, <<0xFF>>, min(left, per_byte), prefix)
    {got, left - length(got)}
  end

  # `count` windows carved at this byte, laid out gap-window-gap-window-…: window
  # `idx` is [a + (2·idx+1)·interval, a + (2·idx+2)·interval]. The leading gap keeps
  # the first start strictly above `a`; the last stop is a + 2·count·interval ≤
  # a + delta < b. Order + disjointness are guaranteed by the even stride.
  defp build_multispan_safe(prefix, a, count, interval) do
    Enum.map(0..(count - 1), fn idx ->
      {build_index(prefix, a + (2 * idx + 1) * interval),
       build_index(prefix, a + (2 * idx + 2) * interval)}
    end)
  end

  defp build_index(prefix, nextbyte), do: build_key([prefix, nextbyte])

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
    build_key([anchor, suffix])
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
        build_key([so_far, a, remainder_prefix(rest1, [])])

      delta ->
        build_key([so_far, a + div(delta, 2)])
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

  @doc """
  Write the two span rows (`:start`/`:stop`) for `node_id`'s extent. The row VALUE is
  `{node_id, type}` — the node kind is carried in the span so element-only / type-filtered
  ordered reads (e.g. `children`) are a single range scan, no per-node record fetch.
  """
  @spec span_put(tid, id, %{
          root: id,
          parent: id | nil,
          start: binary(),
          stop: binary(),
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
  @spec span_children(tid, id, id, binary(), binary()) :: [id]
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
  @spec span_element_children(tid, id, id, binary(), binary()) :: [id]
  def span_element_children(index, root, parent_id, pstart, pstop) do
    :ets.select(index, span_element_children_spec(root, parent_id, pstart, pstop))
  end

  defmatchspecp span_element_children_spec(root, parent_id, pstart, pstop) do
    {{:span, ^root, s, :start, ^parent_id}, {node_id, :element}} when s > pstart and s < pstop ->
      node_id
  end

  # Every span row as `{root, key, kind, parent, node_id, type}` — used by the checker.
  @spec span_rows(tid) :: [{id, binary(), :start | :stop, id | nil, id, atom()}]
  defp span_rows(index) do
    :ets.select(index, span_rows_spec())
  end

  defmatchspecp span_rows_spec() do
    {{:span, root, key, kind, parent}, {node_id, type}} ->
      {root, key, kind, parent, node_id, type}
  end

  @doc "Ordered child ids of `node_id`, read from its record's extent + span rows."
  @spec span_children_of(tid, tid, id) :: [id]
  def span_children_of(nodes, index, node_id) do
    node = fetch!(nodes, node_id)
    span_children(index, ns_root(node, node_id), node_id, node.start, node.stop)
  end

  @doc "Ordered ELEMENT child ids of `node_id` (backs `ParentNode.children`)."
  @spec span_element_children_of(tid, tid, id) :: [id]
  def span_element_children_of(nodes, index, node_id) do
    node = fetch!(nodes, node_id)
    span_element_children(index, ns_root(node, node_id), node_id, node.start, node.stop)
  end

  @doc """
  Ordered child ids of `node_id`, derived purely from the record extents on the
  nodes tid (children are the rows whose `parent` is `node_id`, in `start` order)
  — the index-free adjacency read the tree builder uses while it has no index in
  scope. O(n) scan; the span-row read (`span_children_of/3`) is the O(log n + m)
  path where an index is available.
  """
  @spec children_by_extent(tid, id) :: [id]
  def children_by_extent(nodes, node_id) do
    nodes
    |> :ets.select(children_by_extent_spec(node_id))
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defmatchspecp children_by_extent_spec(node_id) do
    {id, %{parent: ^node_id, start: start}} -> {start, id}
  end

  # ==========================================================================
  # Span rows over the index (mirror of the record extents)
  # ==========================================================================

  @doc """
  (Re)build the span rows for every labeled node straight from its record extent
  — no carve, no `children` field. The extents themselves (written live by the
  mutators) are the order source; this only mirrors them into the index's span
  rows. Retracts each node's old span rows first, so it is idempotent. O(n).
  """
  @spec span_index_all(tid, tid) :: :ok
  def span_index_all(nodes, index) do
    for {id, %{start: start} = data} when start != nil <- :ets.tab2list(nodes) do
      span_retract(index, id)

      span_put(index, id, %{
        root: ns_root(data, id),
        parent: data.parent,
        start: start,
        stop: data.stop,
        type: NodeData.type(data)
      })
    end

    :ok
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
  @spec range_put(tid, reference(), {binary(), non_neg_integer()}, {binary(), non_neg_integer()}) ::
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
          {{binary(), non_neg_integer()}, {binary(), non_neg_integer()}} | nil
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

  @doc """
  The maximum valid Range boundary offset for `node_id`: the child count for an
  element/document/fragment container, the value length for text/comment.
  """
  @spec max_boundary_offset(tid, id) :: non_neg_integer()
  def max_boundary_offset(nodes, node_id) do
    case fetch!(nodes, node_id) do
      %{value: value} when is_binary(value) -> String.length(value)
      _ -> length(children_by_extent(nodes, node_id))
    end
  end

  @doc """
  The id of the node whose extent `start` key equals `extent_key` (the container a
  range boundary pins to), or `nil`. Reverse of the boundary normalization.
  """
  @spec node_at_start_key(tid, binary()) :: id | nil
  def node_at_start_key(nodes, extent_key) do
    case :ets.select(nodes, node_at_start_key_spec(extent_key)) do
      [id | _] -> id
      [] -> nil
    end
  end

  defmatchspecp node_at_start_key_spec(extent_key) do
    {id, %{start: ^extent_key}} -> id
  end

  @doc "Every range boundary row as `{kind, extent_key, ref, offset}`."
  @spec range_all_rows(tid) :: [
          {:range_start | :range_stop, binary(), reference(), non_neg_integer()}
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
          binary(),
          non_neg_integer()
        ) ::
          :ok
  def range_set_boundary(index, kind, ref, extent_key, offset) do
    :ets.match_delete(index, {{kind, :_, ref}, :_})
    :ets.insert(index, {{kind, extent_key, ref}, offset})
    :ok
  end

  # ==========================================================================
  # Consistency checking
  # ==========================================================================

  @doc """
  Assert the document's ETS invariants, returning `:ok` or raising:

    * **adjacency integrity** — the nested-set extents are a valid tree: every
      labeled node's extent is strictly contained in its parent's, and the span
      rows in `index` exactly mirror the record extents (see below);
    * **id index agreement** (when an `index` tid is given) — the id/class/tag/attr
      index exactly mirrors the memberships of every element row.

  Adjacency is now extent-borne (no `children` field): a child's `parent` pointer
  plus its `(start, stop)` window inside the parent's is the edge. A legitimately
  detached subtree (root `parent` nil) passes; a stale parent pointer or a span row
  that disagrees with the record extent fails. Meant to run between operations
  (e.g. an `on_exit` hook), never mid-operation.
  """
  @spec check_consistency!(tid) :: :ok
  @spec check_consistency!(tid, tid) :: :ok
  def check_consistency!(tid, index \\ nil) do
    rows = :ets.tab2list(tid)

    if index do
      check_index!(rows, index)
      check_roots!(rows)
      check_spans!(rows, index)
      check_ranges!(rows, index)
      check_slots!(rows, index)
      check_listeners!(rows, index)
      check_microtasks!(index)
    end

    :ok
  end

  # Root ↔ topology consistency: every node's stored tree-root (`ns_root`) must equal
  # the root reached by walking `.parent` to the top. A parentless node is its own tree
  # root, so its `.root` field must be nil (ns_root resolves to itself). This guards the
  # extent/`.root` bookkeeping against drifting from the actual parent topology — e.g. a
  # detached subtree must be re-rooted, not left pointing at its old tree.
  defp check_roots!(rows) do
    by_id = Map.new(rows)

    for {id, data} <- rows do
      walked = walked_root(by_id, id)
      stored = ns_root(data, id)

      unless walked == stored do
        raise "root drift: #{inspect(id)} stores root #{inspect(stored)} " <>
                "but its parent chain reaches #{inspect(walked)}"
      end
    end

    :ok
  end

  defp walked_root(by_id, id) do
    case Map.fetch!(by_id, id) do
      %{parent: nil} -> id
      %{parent: parent} -> walked_root(by_id, parent)
    end
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

  # Listener consistency: every :listener row must reference a live node. Listeners
  # are primary state (lambdas), so there is nothing to mirror-check — only that a
  # removed/destroyed node left no dangling listener rows behind.
  defp check_listeners!(rows, index) do
    live = MapSet.new(rows, fn {id, _data} -> id end)

    dangling =
      for {{:listener, node_id, _seq}, _listener} <- index_rows_of(index, :listener),
          not MapSet.member?(live, node_id),
          do: node_id

    if dangling != [] do
      raise "dangling listener rows for dead nodes: #{inspect(Enum.uniq(dangling))}"
    end
  end

  # Microtask consistency: OUTSIDE a checkpoint drain the queue must be empty. The
  # drain (handle_continue) runs to completion before the server reads its next
  # message, so any top-level call — including this consistency check — is processed
  # only between operations, when a correctly-behaving checkpoint has already
  # drained. A surviving :microtask row therefore means a checkpoint was skipped or
  # failed to fire — a bug — so we raise rather than tolerate it. (To probe a
  # deliberately-pending microtask, read the :microtask family directly; do not go
  # through check_consistency!.)
  defp check_microtasks!(index) do
    pending = index_rows_of(index, :microtask)

    if pending != [] do
      raise "undrained microtask rows outside a checkpoint: #{inspect(pending)}"
    end
  end

  # Range boundary consistency: every :range_* row must pin to a live container node
  # (its extent_key equals some node's `start`), and its offset must be within the
  # container's bounds — child_count for element/document/fragment, value length for
  # text/comment. Range rows are primary state, so there is nothing to mirror-check.
  defp check_ranges!(rows, index) do
    by_start = Map.new(rows, fn {id, data} -> {Map.get(data, :start), {id, data}} end)
    Enum.each(range_all_rows(index), &check_range_row!(&1, rows, by_start))
  end

  # Slot assignment consistency: every :slot / :assigned / :assigned_host row must
  # reference live nodes, and the `:slot`/`:assigned` views must agree (a node is in
  # slot S's assigned list iff its `:assigned` row points at S).
  defp check_slots!(rows, index) do
    live = MapSet.new(rows, fn {id, _data} -> id end)

    slot_pairs =
      for {{:slot, slot_id, _pos}, node_id} <- index_rows_of(index, :slot), do: {slot_id, node_id}

    assigned =
      for {{:assigned, node_id}, slot_id} <- index_rows_of(index, :assigned),
          into: %{},
          do: {node_id, slot_id}

    Enum.each(slot_pairs, fn {slot_id, node_id} ->
      unless MapSet.member?(live, slot_id) and MapSet.member?(live, node_id) do
        raise "dangling slot row: #{inspect({slot_id, node_id})} references a missing node"
      end

      if Map.get(assigned, node_id) != slot_id do
        raise "slot rows disagree: #{inspect(node_id)} assigned to " <>
                "#{inspect(Map.get(assigned, node_id))} but slot-listed under #{inspect(slot_id)}"
      end
    end)
  end

  defp check_range_row!({kind, extent_key, ref, offset}, rows, by_start) do
    case Map.get(by_start, extent_key) do
      nil ->
        raise "dangling range boundary: #{kind} of #{inspect(ref)} at " <>
                "#{inspect(extent_key)} pins to no live node"

      {id, data} ->
        max = check_max_offset(rows, id, data)

        unless offset >= 0 and offset <= max do
          raise "range offset out of bounds: #{kind} of #{inspect(ref)} " <>
                  "offset #{offset} > max #{max} for #{inspect(id)}"
        end
    end
  end

  # The maximum valid boundary offset for a container, computed from the row list
  # (the checker already holds all rows, so it counts children without an ETS hit).
  defp check_max_offset(_rows, _id, %{value: value}) when is_binary(value),
    do: String.length(value)

  defp check_max_offset(rows, id, _data) do
    Enum.count(rows, fn {_cid, cdata} -> Map.get(cdata, :parent) == id end)
  end

  # Span (extent) consistency, three ways, all field-free:
  #   * backward — every id referenced by a span row exists as a node row;
  #   * containment — each labeled node's extent is strictly inside its parent's,
  #     and children are in start-key order (implied by the span range scan);
  #   * mirror — the span rows equal, exactly, the record extents (span_index_all's
  #     output for the current records).
  # Only runs once the tree has been extent-labeled (any node carries a `start`).
  defp check_spans!(rows, index) do
    node_ids = MapSet.new(rows, fn {id, _data} -> id end)
    spans = span_rows(index)

    if spans != [] do
      check_spans_backward!(spans, node_ids)
      check_spans_mirror!(rows, spans)
      by_id = Map.new(rows)
      Enum.each(rows, fn {id, data} -> check_node_containment!(id, data, by_id) end)
    end
  end

  # backward: no span row points at a node that isn't in the table.
  defp check_spans_backward!(spans, node_ids) do
    Enum.each(spans, fn {_root, _key, _kind, parent, node_id, _type} ->
      unless MapSet.member?(node_ids, node_id) do
        raise "dangling span: node #{inspect(node_id)} not in the nodes table"
      end

      if parent != nil and not MapSet.member?(node_ids, parent) do
        raise "dangling span: parent #{inspect(parent)} not in the nodes table"
      end
    end)
  end

  # mirror: the span rows are exactly the two rows per labeled record extent (value =
  # {node_id, type}) — no missing, stale, or extra span row. This is the invariant
  # span_index_all keeps.
  defp check_spans_mirror!(rows, spans) do
    expected =
      for {id, %{start: start} = data} <- rows,
          start != nil,
          kind_key <- [{start, :start}, {ns_stop(data), :stop}] do
        {key, kind} = kind_key
        {ns_root(data, id), key, kind, data.parent, id, NodeData.type(data)}
      end

    if Enum.sort(expected) != Enum.sort(spans) do
      raise "span rows disagree with record extents: " <>
              "expected #{inspect(Enum.sort(expected))}, got #{inspect(Enum.sort(spans))}"
    end
  end

  # containment: each of `id`'s extent-children sits strictly inside its window.
  defp check_node_containment!(id, data, by_id) do
    {start, stop} = {ns_start(data), ns_stop(data)}

    for {kid, k} <- by_id, k.parent == id do
      unless start < ns_start(k) and ns_start(k) < ns_stop(k) and ns_stop(k) < stop do
        raise "extent containment violated: child #{inspect(kid)} " <>
                "#{inspect({ns_start(k), ns_stop(k)})} not inside " <>
                "#{inspect(id)} #{inspect({start, stop})}"
      end
    end
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

    # Only membership rows (tag/id/class/attr); each family is selected server-side
    # (no whole-table copy), span/range/slot/listener rows never fetched.
    actual =
      for kind <- [:tag, :id, :class, :attr],
          {key, node_id} <- index_rows_of(index, kind),
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
end
