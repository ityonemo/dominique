defmodule DOM.NodeData.Extent do
  @moduledoc """
  Pure nested-set extent arithmetic — the binary order-key math that labels a document's
  tree without any ETS access. A node's `{start, stop}` are binary keys; document order is
  their byte order, and containment is prefix nesting (a child's window sits strictly inside
  its parent's). `interval`/`multispan` carve fresh windows in a gap; `graft` relocates an
  already-labeled subtree by prefix substitution. No records, no index — `DOM.NodeData.NodesTable`
  applies these results to the records.
  """

  @typedoc """
  Extent uses a binary key for ordered searches over a space with arbitrary
  resolution that can be performed inside of an ETS table.
  """
  @type t :: binary()

  # The fixed tree-root extent window (a node is a labeled 1-node tree from birth: its own
  # root, parent nil, this window). Every creator seeds it.
  @root_start <<0x00>>
  @root_stop <<0x80>>

  @doc "The fixed root-window extent `{start, stop}` for a freshly-created tree root."
  @spec root_window() :: {binary(), binary()}
  def root_window, do: {@root_start, @root_stop}

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
end
