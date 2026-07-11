defmodule DOM.Range.Adjust do
  @moduledoc false

  # Live-range boundary adjustment: the WHATWG "range mutation" rules applied to
  # the :range_* rows in the index when the tree mutates under a held range.
  #
  # Boundaries are `{extent_key, offset}` where `extent_key` is the CONTAINER
  # node's own `start` key. Two mechanisms:
  #
  #   * offset shift  — a child inserted/removed before a boundary's index in the
  #     SAME container shifts its child-index offset (the container's own key is
  #     unchanged by append/insert/remove, so the boundary rows are found by that
  #     stable key);
  #   * relocate      — removing a container subtree moves any boundary inside it
  #     to the removed node's old position in its parent; grafting a container
  #     rewrites its `start` key, so boundaries on it are remapped to the new key.
  #
  # These run in the server process (both tids in scope), after the structural
  # mutation. The caller passes the pre-mutation facts each rule needs.

  alias DOM.NodeData.Table

  @doc """
  A node (or `count` nodes) was inserted at child index `at` under `parent_id`.
  Bump the offset of every child-index boundary in `parent_id` whose offset is
  strictly greater than `at`. `parent_key` is `parent_id`'s (unchanged) start key.
  """
  @spec on_insert(:ets.tid(), :ets.tid(), binary(), non_neg_integer(), pos_integer()) :: :ok
  def on_insert(_nodes, index, parent_key, at, count) do
    for {kind, key, ref, offset} <- boundaries_in(index, parent_key), offset > at do
      Table.range_set_boundary(index, kind, ref, key, offset + count)
    end

    :ok
  end

  @doc """
  The subtree rooted at `removed_id` was removed from `parent_id` at child index
  `at`. `parent_key` is `parent_id`'s start key; `removed_keys` is the set of
  start keys of `removed_id` and its (pre-removal) descendants. Boundaries whose
  container was in the removed subtree relocate to `(parent, at)`; boundaries in
  `parent` past `at` decrement.
  """
  @spec on_remove(:ets.tid(), :ets.tid(), binary(), non_neg_integer(), MapSet.t()) :: :ok
  def on_remove(_nodes, index, parent_key, at, removed_keys) do
    for {kind, key, ref, offset} <- Table.range_all_rows(index) do
      cond do
        MapSet.member?(removed_keys, key) ->
          Table.range_set_boundary(index, kind, ref, parent_key, at)

        key == parent_key and offset > at ->
          Table.range_set_boundary(index, kind, ref, key, offset - 1)

        :else ->
          :ok
      end
    end

    :ok
  end

  @doc """
  A container's `start` key changed from `old_key` to `new_key` (a graft moved it
  and/or its subtree). Remap every boundary sitting on any old key to its new key,
  given the `remap` map `%{old_key => new_key}`.
  """
  @spec on_remap(:ets.tid(), :ets.tid(), %{binary() => binary()}) :: :ok
  def on_remap(_nodes, index, remap) do
    for {kind, key, ref, offset} <- Table.range_all_rows(index), new = Map.get(remap, key) do
      Table.range_set_boundary(index, kind, ref, new, offset)
    end

    :ok
  end

  @doc """
  A text node with start key `orig_key` was split at `offset`; the remainder is a
  new node with start key `new_key`. Boundaries in the original text with offset
  greater than `offset` move into the new node (offset - split point).
  """
  @spec on_split(:ets.tid(), :ets.tid(), binary(), binary(), non_neg_integer()) :: :ok
  def on_split(_nodes, index, orig_key, new_key, offset) do
    for {kind, _key, ref, off} <- boundaries_in(index, orig_key), off > offset do
      Table.range_set_boundary(index, kind, ref, new_key, off - offset)
    end

    :ok
  end

  @doc """
  CharacterData `replace data (offset, count, data)` on the node with start key
  `key`: `count` code units at `offset` were replaced by `newlen` new ones. Per the
  spec's replace-data steps, adjust boundaries in this node:

    * a boundary strictly after the replaced region (`boffset > offset + count`)
      shifts by `newlen - count`;
    * a boundary inside the replaced region (`offset < boffset <= offset + count`)
      clamps to `offset`;
    * a boundary at or before `offset` is unchanged.
  """
  @spec on_replace_data(
          :ets.tid(),
          :ets.tid(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  def on_replace_data(_nodes, index, key, offset, count, newlen) do
    for {kind, _key, ref, boffset} <- boundaries_in(index, key) do
      cond do
        boffset > offset + count ->
          Table.range_set_boundary(index, kind, ref, key, boffset + newlen - count)

        boffset > offset ->
          Table.range_set_boundary(index, kind, ref, key, offset)

        :else ->
          :ok
      end
    end

    :ok
  end

  # All range boundary rows whose container key is `key`.
  defp boundaries_in(index, key) do
    Enum.filter(Table.range_all_rows(index), fn {_kind, k, _ref, _off} -> k == key end)
  end
end
