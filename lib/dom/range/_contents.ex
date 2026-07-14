defmodule DOM.Range.Contents do
  @moduledoc false

  # The WHATWG Range "clone the contents" / "extract" algorithms, over the nodes
  # ETS tid. Boundaries are `{container_id, offset}` (offset = child index for
  # element/document/fragment, char index for text/comment). `clone/5` builds a
  # detached fragment of copies; the fragment's children are returned as a list of
  # freshly-cloned node ids (the caller appends them to a DocumentFragment).
  #
  # Every produced clone is a detached, fully extent-labeled tree (via DOM.NodeData.clone
  # or a fresh Text node), ready to be placed under the fragment.

  alias DOM.NodeData
  alias DOM.NodeData.NodesTable

  @doc """
  Clone the contents of the range `[(sc, so), (ec, eo)]` into a list of detached
  node ids (document order) to append to a fragment. Pure copy — the source tree
  is untouched.
  """
  @spec clone(
          NodesTable.tid(),
          NodesTable.tid(),
          NodesTable.id(),
          non_neg_integer(),
          NodesTable.id(),
          non_neg_integer()
        ) ::
          [NodesTable.id()]
  def clone(nodes, index, sc, so, ec, eo) do
    cond do
      # collapsed
      sc == ec and so == eo ->
        []

      # both boundaries in the same character-data node: one clone of the substring
      sc == ec and character_data?(nodes, sc) ->
        [clone_char_slice(nodes, index, sc, so, eo)]

      :else ->
        clone_spanning(nodes, index, sc, so, ec, eo)
    end
  end

  @doc """
  EXTRACT the contents of `[(sc, so), (ec, eo)]`: move the selected content out of
  the source tree into a list of detached node ids (document order). Partial text
  nodes are truncated in place; fully-contained subtrees are detached; partial
  start/end elements are shallow-cloned to hold their extracted descendants (the
  element itself stays in the source). Mirrors `clone/5` but moves rather than
  copies.
  """
  @spec extract(
          NodesTable.tid(),
          NodesTable.tid(),
          NodesTable.id(),
          non_neg_integer(),
          NodesTable.id(),
          non_neg_integer()
        ) ::
          [NodesTable.id()]
  def extract(nodes, index, sc, so, ec, eo) do
    cond do
      sc == ec and so == eo ->
        []

      sc == ec and character_data?(nodes, sc) ->
        [extract_char_slice(nodes, index, sc, so, eo)]

      :else ->
        extract_spanning(nodes, index, sc, so, ec, eo)
    end
  end

  defp extract_spanning(nodes, index, sc, so, ec, eo) do
    common = common_ancestor(nodes, sc, ec)
    start_part = extract_start_side(nodes, index, common, sc, so)
    middle = extract_contained_children(nodes, index, common, sc, so, ec, eo)
    end_part = extract_end_side(nodes, index, common, ec, eo)
    start_part ++ middle ++ end_part
  end

  # Extract the partial start node: char slice (truncating the source text), or a
  # shallow clone of the start path element holding its extracted descendants.
  defp extract_start_side(nodes, index, common, sc, so) do
    if sc == common do
      []
    else
      child = child_on_path(nodes, common, sc)

      if child == sc and character_data?(nodes, sc) do
        [extract_char_slice(nodes, index, sc, so, char_len(nodes, sc))]
      else
        holder = shallow_clone(nodes, index, child)

        append_all(
          nodes,
          index,
          holder,
          extract(nodes, index, sc, so, child, max_offset(nodes, child))
        )

        [holder]
      end
    end
  end

  defp extract_end_side(nodes, index, common, ec, eo) do
    if ec == common do
      []
    else
      child = child_on_path(nodes, common, ec)

      if child == ec and character_data?(nodes, ec) do
        [extract_char_slice(nodes, index, ec, 0, eo)]
      else
        holder = shallow_clone(nodes, index, child)
        append_all(nodes, index, holder, extract(nodes, index, child, 0, ec, eo))
        [holder]
      end
    end
  end

  # Detach every fully-contained child of `common` from the source (they become fragment
  # children directly, no clone) — keeping each labeled via NodeData.detach. Document order.
  defp extract_contained_children(nodes, index, common, sc, so, ec, eo) do
    kids = NodesTable.children_by_extent(nodes, common)
    from = contained_lo(nodes, common, sc, so, kids)
    to = contained_hi(nodes, common, ec, eo, kids)
    contained = Enum.slice(kids, from, max(to - from, 0))
    Enum.each(contained, &NodeData.detach(nodes, index, &1))
    contained
  end

  # A new character node holding `value[from..to]`, REMOVED from the source node's
  # value (the source keeps everything outside [from, to)).
  defp extract_char_slice(nodes, index, id, from, to) do
    data = NodesTable.fetch!(nodes, id)
    extracted = String.slice(data.value, from, to - from)
    kept = String.slice(data.value, 0, from) <> String.slice(data.value, to, char_len(nodes, id))
    NodesTable.set_value(nodes, id, kept)
    new_char_node(nodes, index, data, extracted)
  end

  # The general case: start container, fully-contained middle children, end
  # container — relative to their common ancestor.
  defp clone_spanning(nodes, index, sc, so, ec, eo) do
    common = common_ancestor(nodes, sc, ec)

    start_clone = clone_start_side(nodes, index, common, sc, so, ec, eo)
    middle = clone_contained_children(nodes, index, common, sc, so, ec, eo)
    end_clone = clone_end_side(nodes, index, common, sc, ec, eo)

    start_clone ++ middle ++ end_clone
  end

  # Clone for the start boundary side: the partially-contained start node (the
  # child of `common` on the path to sc), unless sc IS `common` (no partial start).
  # If that node is character data (sc itself), clone its tail slice; if it is an
  # element, shallow-clone it and recurse into the sub-range from (sc, so) to the
  # end of the node.
  defp clone_start_side(nodes, index, common, sc, so, _ec, _eo) do
    if sc == common do
      []
    else
      child = child_on_path(nodes, common, sc)

      if child == sc and character_data?(nodes, sc) do
        [clone_char_slice(nodes, index, sc, so, char_len(nodes, sc))]
      else
        clone = shallow_clone(nodes, index, child)
        sub = clone(nodes, index, sc, so, child, max_offset(nodes, child))
        append_all(nodes, index, clone, sub)
        [clone]
      end
    end
  end

  # Clone for the end boundary side, mirror of the start side: from the start of
  # the end path node to (ec, eo).
  defp clone_end_side(nodes, index, common, _sc, ec, eo) do
    if ec == common do
      []
    else
      child = child_on_path(nodes, common, ec)

      if child == ec and character_data?(nodes, ec) do
        [clone_char_slice(nodes, index, ec, 0, eo)]
      else
        clone = shallow_clone(nodes, index, child)
        sub = clone(nodes, index, child, 0, ec, eo)
        append_all(nodes, index, clone, sub)
        [clone]
      end
    end
  end

  # Deep-clone every child of `common` fully contained in the range. A child is
  # contained when it is strictly after the start boundary and strictly before the
  # end boundary. The boundaries are expressed as child indices of `common`: when a
  # boundary's container IS `common`, its offset is the index directly; otherwise
  # the boundary sits inside the path child (partially contained, handled by the
  # start/end sides), so contained children begin just after / end just before it.
  defp clone_contained_children(nodes, index, common, sc, so, ec, eo) do
    kids = NodesTable.children_by_extent(nodes, common)
    from = contained_lo(nodes, common, sc, so, kids)
    to = contained_hi(nodes, common, ec, eo, kids)

    kids
    |> Enum.slice(from, max(to - from, 0))
    |> Enum.map(&DOM.NodeData.clone(nodes, index, &1, true))
  end

  # First fully-contained child index: `so` when sc is common (the boundary is a
  # child index), else index-after the partially-contained start path child.
  defp contained_lo(tid, common, sc, so, kids) do
    if sc == common, do: so, else: index_of(kids, child_on_path(tid, common, sc)) + 1
  end

  # One-past the last fully-contained child index: `eo` when ec is common, else the
  # index of the partially-contained end path child (which is not fully contained).
  defp contained_hi(tid, common, ec, eo, kids) do
    if ec == common, do: eo, else: index_of(kids, child_on_path(tid, common, ec))
  end

  defp index_of(list, elem), do: Enum.find_index(list, &(&1 == elem))

  # ==========================================================================
  # Path / containment helpers (via extents)
  # ==========================================================================

  # The child of `ancestor` on the path down to `node` (node itself if it is a
  # direct child; nil if node == ancestor).
  defp child_on_path(_tid, ancestor, ancestor), do: nil

  defp child_on_path(tid, ancestor, node) do
    case NodesTable.parent(tid, node) do
      ^ancestor -> node
      nil -> nil
      parent -> child_on_path(tid, ancestor, parent)
    end
  end

  # The common ancestor of two nodes (deepest node containing both).
  defp common_ancestor(tid, a, b) do
    a_chain = ancestor_chain(tid, a)
    b_set = MapSet.new(ancestor_chain(tid, b))
    Enum.find(a_chain, &MapSet.member?(b_set, &1))
  end

  defp ancestor_chain(tid, id) do
    case NodesTable.parent(tid, id) do
      nil -> [id]
      parent -> [id | ancestor_chain(tid, parent)]
    end
  end

  # ==========================================================================
  # Clone primitives
  # ==========================================================================

  # A fresh Text/Comment node holding `value[from..to]` (a slice of char data).
  defp clone_char_slice(nodes, index, id, from, to) do
    data = NodesTable.fetch!(nodes, id)
    slice = String.slice(data.value, from, to - from)
    new_char_node(nodes, index, data, slice)
  end

  defp new_char_node(nodes, index, %NodeData.Text{}, value),
    do: DOM.NodeData.create_text(nodes, index, value)

  defp new_char_node(nodes, index, %NodeData.Comment{}, value),
    do: DOM.NodeData.create_comment(nodes, index, value)

  defp shallow_clone(nodes, index, id), do: DOM.NodeData.clone(nodes, index, id, false)

  # The produced ids are now fully-labeled subtrees — MOVE them under `parent` via graft_into
  # (both tables), not a record-only append.
  defp append_all(nodes, index, parent, ids),
    do: NodeData.graft_into(nodes, index, parent, ids, :last)

  # ==========================================================================
  # Small reads
  # ==========================================================================

  defp character_data?(tid, id) do
    case NodesTable.fetch!(tid, id) do
      %NodeData.Text{} -> true
      %NodeData.Comment{} -> true
      _ -> false
    end
  end

  defp char_len(tid, id), do: String.length(NodesTable.fetch!(tid, id).value)
  defp max_offset(tid, id), do: NodesTable.max_boundary_offset(tid, id)
end
