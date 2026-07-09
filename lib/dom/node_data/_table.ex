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

    for {kind, value} <- memberships(element) do
      :ets.insert(index, {{kind, value, make_ref()}, node_id})
    end

    :ok
  end

  @doc "Delete all index rows pointing at `node_id`."
  @spec index_retract(tid, id) :: :ok
  def index_retract(index, node_id) do
    for kind <- [:tag, :id, :class] do
      :ets.match_delete(index, {{kind, :_, :_}, node_id})
    end

    :ok
  end

  # The {kind, value} memberships an element contributes to the index: its tag,
  # ids, and (deduped) class tokens. Single source of truth for both index_put
  # and the consistency checker.
  defp memberships(%NodeData.Element{local_name: local_name, attributes: attributes}) do
    ids = for {"id", value} <- attributes, do: {:id, value}

    classes =
      for {"class", value} <- attributes, token <- class_tokens(value), do: {:class, token}

    [{:tag, local_name} | ids ++ classes]
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
    if index, do: check_index!(rows, index)
    :ok
  end

  # The index must equal, as a sorted list of {kind, value, node} triples, the
  # id/class memberships of the element rows — no missing, stale, duplicate, or
  # dangling row (class tokens deduped as in index_put).
  defp check_index!(rows, index) do
    expected =
      for {node_id, %NodeData.Element{} = element} <- rows,
          {kind, value} <- memberships(element),
          do: {kind, value, node_id}

    actual =
      for {{kind, value, _ref}, node_id} <- :ets.tab2list(index), do: {kind, value, node_id}

    if Enum.sort(expected) != Enum.sort(actual) do
      raise "inconsistent index: expected #{inspect(Enum.sort(expected))}, " <>
              "got #{inspect(Enum.sort(actual))}"
    end
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
