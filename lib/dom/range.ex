defmodule DOM.Range do
  @moduledoc """
  A live DOM `Range`: a contiguous `start..end` span across the tree, defined by
  two boundary points. Each boundary is a `{container, offset}` — `offset` is a
  child index for element/document/fragment containers, a character index for
  text/comment.

  A range is a handle `%DOM.Range{server, range_id}` into range rows the document
  server keeps in its index table (see `DOM.NodeData.Table` `range_*`). The
  `range_id` IS the monitor ref of the range's owner: the server monitors the
  owner process at `create_range/2`, so an abandoned range is reclaimed when its
  owner dies, and `detach/1` reclaims it explicitly.

  Boundaries are stored in extent-key space, so document-order comparison
  (`compare_boundary_points/3`, `collapsed?/1`, `is_point_in_range/3`) is a
  lexicographic key comparison — no tree walk.

  Setters return a NEW `%DOM.Range{}` (same `range_id`) after rewriting the
  server-side rows; the handle itself is immutable, the boundaries it names are
  server state.
  """

  alias DOM.Node
  alias DOM.NodeData.Table

  @enforce_keys [:server, :range_id]
  defstruct [:server, :range_id]

  @type t :: %__MODULE__{server: GenServer.server(), range_id: reference()}
  @type how :: :start_to_start | :start_to_end | :end_to_end | :end_to_start

  # ==========================================================================
  # Lifecycle
  # ==========================================================================

  @doc """
  Create a new range on `document`, collapsed at `(document, 0)`. The server
  monitors the **owner** process (default: the caller) so the range is reclaimed
  when the owner dies; `owner:` overrides it (e.g. an event callback closing over
  its authoring process). The owner may not be the document server itself.
  """
  @spec create_range(Node.t(), keyword()) :: t()
  def create_range(%Node{type: :document} = document, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    if owner == document.server do
      raise ArgumentError, "a range may not be owned by the document server process"
    end

    range_id = DOM._range_create(document.server, document.node_id, owner)
    %__MODULE__{server: document.server, range_id: range_id}
  end

  @doc "Release the range from the server (idempotent). The handle becomes detached."
  @spec detach(t()) :: :ok
  def detach(%__MODULE__{} = range) do
    DOM._range_detach(range.server, range.range_id)
  end

  @doc "Whether the range has been detached / evicted (no boundary rows remain)."
  @spec detached?(t()) :: boolean()
  def detached?(%__MODULE__{} = range) do
    DOM._atomic_ets_op(range.server, fn _nodes, index ->
      not Table.range_present?(index, range.range_id)
    end)
  end

  # ==========================================================================
  # Boundary setters (return a new %DOM.Range{})
  # ==========================================================================

  @doc "Set the start boundary to `(container, offset)`."
  @spec set_start(t(), Node.t(), non_neg_integer()) :: t()
  def set_start(%__MODULE__{} = range, %Node{} = container, offset) do
    update(range, fn nodes, _index, {_start, stop} ->
      with {:ok, new_start} <- normalize(nodes, container, offset) do
        {new_start, clamp_end(new_start, stop)}
      end
    end)
  end

  @doc "Set the end boundary to `(container, offset)`."
  @spec set_end(t(), Node.t(), non_neg_integer()) :: t()
  def set_end(%__MODULE__{} = range, %Node{} = container, offset) do
    update(range, fn nodes, _index, {start, _stop} ->
      with {:ok, new_end} <- normalize(nodes, container, offset) do
        {clamp_start(start, new_end), new_end}
      end
    end)
  end

  @doc "Set the start boundary to just before `node` (in its parent)."
  @spec set_start_before(t(), Node.t()) :: t()
  def set_start_before(range, node), do: at_node(range, node, :before, :start)

  @doc "Set the start boundary to just after `node`."
  @spec set_start_after(t(), Node.t()) :: t()
  def set_start_after(range, node), do: at_node(range, node, :after, :start)

  @doc "Set the end boundary to just before `node`."
  @spec set_end_before(t(), Node.t()) :: t()
  def set_end_before(range, node), do: at_node(range, node, :before, :end)

  @doc "Set the end boundary to just after `node`."
  @spec set_end_after(t(), Node.t()) :: t()
  def set_end_after(range, node), do: at_node(range, node, :after, :end)

  @doc "Select `node`: start before it, end after it (both in its parent)."
  @spec select_node(t(), Node.t()) :: t()
  def select_node(%__MODULE__{} = range, %Node{} = node) do
    update(range, fn nodes, _index, _bounds ->
      {parent_id, index_in_parent} = node_position!(nodes, node)
      pkey = start_key!(nodes, parent_id)
      {{pkey, index_in_parent}, {pkey, index_in_parent + 1}}
    end)
  end

  @doc "Select `node`'s contents: start at offset 0, end at its last child/char."
  @spec select_node_contents(t(), Node.t()) :: t()
  def select_node_contents(%__MODULE__{} = range, %Node{} = node) do
    update(range, fn nodes, _index, _bounds ->
      key = start_key!(nodes, node.node_id)
      max = Table.max_boundary_offset(nodes, node.node_id)
      {{key, 0}, {key, max}}
    end)
  end

  @doc "Collapse the range onto one boundary (`to_start?` chooses which)."
  @spec collapse(t(), boolean()) :: t()
  def collapse(%__MODULE__{} = range, to_start?) do
    update(range, fn _nodes, _index, {start, stop} ->
      point = if to_start?, do: start, else: stop
      {point, point}
    end)
  end

  # ==========================================================================
  # Boundary reads
  # ==========================================================================

  @doc "The start boundary's container node."
  @spec start_container(t()) :: Node.t()
  def start_container(range), do: read(range, fn nodes, {{k, _o}, _} -> container(nodes, k) end)

  @doc "The start boundary's offset."
  @spec start_offset(t()) :: non_neg_integer()
  def start_offset(range), do: read(range, fn _n, {{_k, o}, _} -> o end)

  @doc "The end boundary's container node."
  @spec end_container(t()) :: Node.t()
  def end_container(range), do: read(range, fn nodes, {_, {k, _o}} -> container(nodes, k) end)

  @doc "The end boundary's offset."
  @spec end_offset(t()) :: non_neg_integer()
  def end_offset(range), do: read(range, fn _n, {_, {_k, o}} -> o end)

  @doc "Whether start and end are the same boundary point."
  @spec collapsed?(t()) :: boolean()
  def collapsed?(range), do: read(range, fn _n, {start, stop} -> start == stop end)

  @doc "The deepest node that contains both boundary containers."
  @spec common_ancestor_container(t()) :: Node.t()
  def common_ancestor_container(range) do
    DOM._atomic_ets_op(range.server, fn nodes, index ->
      {{start_key, _}, {stop_key, _}} = boundaries!(index, range.range_id)
      a = Table.node_at_start_key(nodes, start_key)
      b = Table.node_at_start_key(nodes, stop_key)
      node_handle(range.server, nodes, common_ancestor(nodes, a, b))
    end)
  end

  # ==========================================================================
  # Comparison
  # ==========================================================================

  @doc """
  Compare a boundary of this range against a boundary of `other`, per `how`:
  `:start_to_start | :start_to_end | :end_to_end | :end_to_start`. Returns -1, 0,
  or 1 (this-boundary before / equal / after other-boundary in document order).
  """
  @spec compare_boundary_points(t(), how(), t()) :: -1 | 0 | 1
  def compare_boundary_points(%__MODULE__{server: server} = range, how, %__MODULE__{} = other) do
    DOM._atomic_ets_op(server, fn _nodes, index ->
      {this_start, this_end} = boundaries!(index, range.range_id)
      {other_start, other_end} = boundaries!(index, other.range_id)
      {a, b} = boundary_pair(how, {this_start, this_end}, {other_start, other_end})
      compare_boundaries(a, b)
    end)
  end

  @doc "Whether `(node, offset)` lies within the range (−1 before, 0 in, 1 after)."
  @spec compare_point(t(), Node.t(), non_neg_integer()) :: -1 | 0 | 1
  def compare_point(%__MODULE__{} = range, %Node{} = node, offset) do
    result =
      DOM._atomic_ets_op(range.server, fn nodes, index ->
        {start, stop} = boundaries!(index, range.range_id)

        with {:ok, point} <- normalize(nodes, node, offset) do
          point_vs_range(point, start, stop)
        end
      end)

    case result do
      {:error, :index_size} -> raise DOM.IndexSizeError
      cmp -> cmp
    end
  end

  # ==========================================================================
  # Content operations
  # ==========================================================================

  @doc """
  Return a DocumentFragment holding a COPY of the range's contents (the source
  tree is untouched). A collapsed range yields an empty fragment.
  """
  @spec clone_contents(t()) :: Node.t()
  def clone_contents(%__MODULE__{} = range) do
    DOM._range_clone_contents(range.server, range.range_id)
  end

  @doc """
  Move the range's contents into a DocumentFragment (removing them from the source
  tree) and collapse the range to its start. Returns the fragment.
  """
  @spec extract_contents(t()) :: Node.t()
  def extract_contents(%__MODULE__{} = range) do
    DOM._range_extract_contents(range.server, range.range_id)
  end

  @doc "Delete the range's contents from the tree and collapse the range to its start."
  @spec delete_contents(t()) :: :ok
  def delete_contents(%__MODULE__{} = range) do
    DOM._range_delete_contents(range.server, range.range_id)
  end

  # -1 if point is before the range, 1 if after, 0 if within (inclusive).
  defp point_vs_range(point, start, stop) do
    cond do
      compare_boundaries(point, start) < 0 -> -1
      compare_boundaries(point, stop) > 0 -> 1
      :else -> 0
    end
  end

  @doc "Whether `(node, offset)` is within the range."
  @spec is_point_in_range(t(), Node.t(), non_neg_integer()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_point_in_range(range, node, offset), do: compare_point(range, node, offset) == 0

  # ==========================================================================
  # Helpers — server round-trips
  # ==========================================================================

  # Run `fun.(nodes, index, {start, stop})` to compute the new boundaries, write
  # them, and return a fresh handle. `fun` may signal a bad offset by returning
  # `{:error, :index_size}` (raised client-side, so the caller sees a clean
  # exception rather than a server-process exit). Boundaries are `{extent_key,
  # offset}`.
  defp update(%__MODULE__{} = range, fun) do
    result =
      DOM._atomic_ets_op(range.server, fn nodes, index ->
        current = boundaries!(index, range.range_id)

        case fun.(nodes, index, current) do
          {:error, reason} ->
            {:error, reason}

          {new_start, new_stop} ->
            Table.range_put(index, range.range_id, new_start, new_stop)
            :ok
        end
      end)

    case result do
      :ok -> range
      {:error, :index_size} -> raise DOM.IndexSizeError
    end
  end

  # Run a pure read `fun.(nodes, {start, stop})` against the range's boundaries.
  defp read(%__MODULE__{} = range, fun) do
    DOM._atomic_ets_op(range.server, fn nodes, index ->
      fun.(nodes, boundaries!(index, range.range_id))
    end)
  end

  # A setter that positions a boundary relative to `node` (before/after) in its
  # parent, updating either the :start or :end side (and pulling the other along).
  defp at_node(%__MODULE__{} = range, %Node{} = node, where, side) do
    update(range, fn nodes, _index, {start, stop} ->
      {parent_id, i} = node_position!(nodes, node)
      pkey = start_key!(nodes, parent_id)
      point = {pkey, if(where == :after, do: i + 1, else: i)}

      case side do
        :start -> {point, clamp_end(point, stop)}
        :end -> {clamp_start(start, point), point}
      end
    end)
  end

  # ==========================================================================
  # Helpers — boundary math (pure over {extent_key, offset})
  # ==========================================================================

  # Normalize a user `{container, offset}` into a boundary `{extent_key, offset}`,
  # validating the offset against the container's max. Returns `{:ok, boundary}` or
  # `{:error, :index_size}` (the caller raises client-side).
  defp normalize(nodes, %Node{node_id: id}, offset) do
    max = Table.max_boundary_offset(nodes, id)

    if offset < 0 or offset > max do
      {:error, :index_size}
    else
      {:ok, {start_key!(nodes, id), offset}}
    end
  end

  # Compare two boundaries in document order: extent key, then offset.
  defp compare_boundaries({key_a, off_a}, {key_b, off_b}) do
    cond do
      key_a < key_b -> -1
      key_a > key_b -> 1
      off_a < off_b -> -1
      off_a > off_b -> 1
      :else -> 0
    end
  end

  # Keep the range ordered (start <= end). `clamp_end(start, end)` keeps `end` if
  # it is at/after `start`, else pulls it back to `start` (a set_start past the end
  # collapses the range). `clamp_start(start, end)` is the mirror. Both return the
  # value that keeps `start <= end`, collapsing when the two cross.
  defp clamp_end(start, endp), do: if(compare_boundaries(start, endp) <= 0, do: endp, else: start)

  defp clamp_start(start, endp),
    do: if(compare_boundaries(start, endp) <= 0, do: start, else: endp)

  # `select_node`: the node's parent id and its index among the parent's children.
  defp node_position!(nodes, %Node{node_id: id}) do
    parent_id = Table.parent(nodes, id)
    kids = Table.children_by_extent(nodes, parent_id)
    {parent_id, Enum.find_index(kids, &(&1 == id))}
  end

  defp start_key!(nodes, id), do: Table.fetch!(nodes, id).start

  # The boundary pair (a, b) to compare for a given `how`.
  defp boundary_pair(:start_to_start, {ts, _te}, {os, _oe}), do: {ts, os}
  defp boundary_pair(:start_to_end, {ts, _te}, {_os, oe}), do: {ts, oe}
  defp boundary_pair(:end_to_end, {_ts, te}, {_os, oe}), do: {te, oe}
  defp boundary_pair(:end_to_start, {_ts, te}, {os, _oe}), do: {te, os}

  # Read a range's boundaries or raise if it is detached.
  defp boundaries!(index, ref) do
    case Table.range_boundaries(index, ref) do
      nil -> raise ArgumentError, "range #{inspect(ref)} is detached"
      bounds -> bounds
    end
  end

  # The container handle for a boundary's extent key (reverse lookup).
  defp container(nodes, extent_key) do
    id = Table.node_at_start_key(nodes, extent_key)
    node_handle(self_server(), nodes, id)
  end

  # The deepest common ancestor of two node ids (walk parents to a shared set).
  defp common_ancestor(nodes, a, b) do
    a_chain = ancestor_chain(nodes, a)
    b_set = MapSet.new(ancestor_chain(nodes, b))
    Enum.find(a_chain, &MapSet.member?(b_set, &1))
  end

  defp ancestor_chain(nodes, id) do
    case Table.parent(nodes, id) do
      nil -> [id]
      parent -> [id | ancestor_chain(nodes, parent)]
    end
  end

  # The atomic-op closures run in the server process; the handle needs the server
  # pid. Within an _atomic_ets_op the server IS self(), so this returns it.
  defp self_server, do: self()

  defp node_handle(server, nodes, id) do
    type = nodes |> Table.fetch!(id) |> DOM.NodeData.type()
    %Node{server: server, node_id: id, type: type}
  end
end
