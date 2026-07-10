defmodule DOM.HTML.TreeBuilder.Tree do
  @moduledoc """
  The in-memory tree the HTML tree builder mutates during construction — plain
  Elixir data, no ETS, no extents. The WHATWG tree-construction algorithm is
  mutate-in-place (foster parenting, the adoption agency, active-formatting
  reconstruction, text coalescing all read the current tree back to decide the
  next move), so this models exactly the operations the builder needs: create
  nodes, append/insert-before/remove/reparent, and read node_name / type / value
  / children / parent / attributes.

  Node ids are `make_ref()`s (the same identities the builder's open-element
  stack, active-formatting list and template `contents` map hold), so a node's
  identity is stable across the whole parse.

  At EOF the finished tree is **bulk-loaded** into the real node table + index in
  one pass (`bulk_load/4`): a recursive descent that assigns each parent's child
  list its nested-set extents with a single `interval/2` (one child) or
  `multispan/3` (many) call, then writes the `DOM.NodeData.*` records and their
  index rows. No per-intermediate extent math — extents are computed once, over
  the final tree.

  A node is `%{kind, parent, children, …kind-fields}`:

    * `:element`  — `local_name`, `namespace`, `attributes`, optional `content`
      (a template's content fragment id)
    * `:text` / `:comment` — `value`
    * `:doctype` — `name`, `public_id`, `system_id`
    * `:document` / `:document_fragment` — container only
  """

  alias DOM.NodeData
  alias DOM.NodeData.Table

  @enforce_keys [:nodes]
  defstruct [:nodes]

  @type id :: reference()
  @type t :: %__MODULE__{nodes: %{id => map()}}

  # ==========================================================================
  # Construction
  # ==========================================================================

  @doc "A fresh tree seeded with a document root; returns `{tree, document_id}`."
  @spec new_document() :: {t(), id}
  def new_document do
    id = make_ref()
    {%__MODULE__{nodes: %{id => new_node(:document)}}, id}
  end

  @doc "A fresh tree whose root is the given (already-minted) document id."
  @spec new(id) :: t()
  def new(document_id) do
    %__MODULE__{nodes: %{document_id => new_node(:document)}}
  end

  @spec create_element(t(), String.t()) :: {t(), id}
  def create_element(tree, local_name) do
    put_new(tree, new_node(:element, local_name: local_name, namespace: :html, attributes: []))
  end

  @spec create_element_ns(t(), String.t(), atom(), [{String.t(), String.t()}]) :: {t(), id}
  def create_element_ns(tree, local_name, namespace, attributes) do
    put_new(
      tree,
      new_node(:element, local_name: local_name, namespace: namespace, attributes: attributes)
    )
  end

  @spec create_text(t(), String.t()) :: {t(), id}
  def create_text(tree, value), do: put_new(tree, new_node(:text, value: value))

  @spec create_comment(t(), String.t()) :: {t(), id}
  def create_comment(tree, value), do: put_new(tree, new_node(:comment, value: value))

  @spec create_doctype(t(), String.t(), String.t() | nil, String.t() | nil) :: {t(), id}
  def create_doctype(tree, name, public_id, system_id) do
    put_new(tree, new_node(:doctype, name: name, public_id: public_id, system_id: system_id))
  end

  @doc """
  Create a template element together with its content DocumentFragment, linked
  via the element's `content` field. Returns `{tree, template_id, content_id}`.
  """
  @spec create_template(t(), [{String.t(), String.t()}]) :: {t(), id, id}
  def create_template(tree, attributes) do
    {tree, content} = put_new(tree, new_node(:document_fragment))

    {tree, template} =
      put_new(
        tree,
        new_node(:element,
          local_name: "template",
          namespace: :html,
          attributes: attributes,
          content: content
        )
      )

    {tree, template, content}
  end

  # A node map for `kind` with the given kind-fields, detached (no parent, no kids).
  defp new_node(kind, fields \\ []) do
    Enum.into(fields, %{kind: kind, parent: nil, children: []})
  end

  defp put_new(%__MODULE__{nodes: nodes} = tree, data) do
    id = make_ref()
    {%{tree | nodes: Map.put(nodes, id, data)}, id}
  end

  # ==========================================================================
  # Structure mutation
  # ==========================================================================

  @doc "Append `child` to `parent`, detaching it from any current parent first."
  @spec append_child(t(), id, id) :: t()
  def append_child(tree, parent, child) do
    tree = detach(tree, child)
    tree = update(tree, parent, &%{&1 | children: &1.children ++ [child]})
    update(tree, child, &%{&1 | parent: parent})
  end

  @doc "Insert `child` immediately before `reference` under `parent` (a move)."
  @spec insert_before(t(), id, id, id) :: t()
  def insert_before(tree, parent, child, reference) do
    tree = detach(tree, child)

    tree =
      update(tree, parent, fn p ->
        {before, rest} = Enum.split_while(p.children, &(&1 != reference))
        %{p | children: before ++ [child | rest]}
      end)

    update(tree, child, &%{&1 | parent: parent})
  end

  @doc "Remove `child` from `parent` (child keeps its own subtree, parent nil)."
  @spec remove_child(t(), id, id) :: t()
  def remove_child(tree, parent, child) do
    tree = update(tree, parent, &%{&1 | children: List.delete(&1.children, child)})
    update(tree, child, &%{&1 | parent: nil})
  end

  # Detach `child` from its current parent's child list (no-op if detached).
  defp detach(tree, child) do
    case fetch(tree, child).parent do
      nil -> tree
      parent -> update(tree, parent, &%{&1 | children: List.delete(&1.children, child)})
    end
  end

  # ==========================================================================
  # Data mutation
  # ==========================================================================

  @spec set_attribute(t(), id, String.t(), String.t()) :: t()
  def set_attribute(tree, id, name, value) do
    update(tree, id, &%{&1 | attributes: List.keystore(&1.attributes, name, 0, {name, value})})
  end

  @spec set_value(t(), id, String.t()) :: t()
  def set_value(tree, id, value), do: update(tree, id, &%{&1 | value: value})

  # ==========================================================================
  # Reads
  # ==========================================================================

  @spec node_name(t(), id) :: String.t()
  def node_name(tree, id), do: node_name_of(fetch(tree, id))

  @spec node_type(t(), id) :: atom()
  def node_type(tree, id), do: fetch(tree, id).kind

  @spec children(t(), id) :: [id]
  def children(tree, id), do: fetch(tree, id).children

  @spec parent(t(), id) :: id | nil
  def parent(tree, id), do: fetch(tree, id).parent

  @spec value(t(), id) :: String.t()
  def value(tree, id), do: fetch(tree, id).value

  @spec namespace(t(), id) :: atom() | nil
  def namespace(tree, id), do: Map.get(fetch(tree, id), :namespace)

  @spec content(t(), id) :: id | nil
  def content(tree, id), do: Map.get(fetch(tree, id), :content)

  @spec get_attribute(t(), id, String.t()) :: String.t() | nil
  def get_attribute(tree, id, name) do
    case List.keyfind(fetch(tree, id).attributes, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  @spec has_attribute(t(), id, String.t()) :: boolean()
  def has_attribute(tree, id, name), do: List.keymember?(fetch(tree, id).attributes, name, 0)

  @doc "The `DOM.Node` kind atom of `id` (:element, :text, …)."
  @spec type(t(), id) :: atom()
  def type(tree, id), do: fetch(tree, id).kind

  defp node_name_of(%{kind: :element, local_name: name}), do: name
  defp node_name_of(%{kind: :text}), do: "#text"
  defp node_name_of(%{kind: :comment}), do: "#comment"
  defp node_name_of(%{kind: :document}), do: "#document"
  defp node_name_of(%{kind: :document_fragment}), do: "#document-fragment"
  defp node_name_of(%{kind: :doctype, name: name}), do: name

  defp fetch(%__MODULE__{nodes: nodes}, id), do: Map.fetch!(nodes, id)

  defp update(%__MODULE__{nodes: nodes} = tree, id, fun) do
    %{tree | nodes: Map.update!(nodes, id, fun)}
  end

  # ==========================================================================
  # Bulk load into the ETS node table + index (via multispan)
  # ==========================================================================

  @doc """
  Materialize the whole tree rooted at `root_id` into the node table `tid` and the
  index `index`. `root_id`'s record is assumed already present (the pre-inserted
  Document); every other node is written here with its `DOM.NodeData.*` record,
  nested-set extent, and index rows. Extents are carved once per child list with
  `interval/2` (single child) or `multispan/3` (many). Returns `:ok`.
  """
  @spec bulk_load(t(), :ets.tid(), :ets.tid(), id) :: :ok
  def bulk_load(tree, tid, index, root_id) do
    load_node(tree, tid, index, root_id, root_id, nil, <<0x00>>, <<0x80>>)
    :ok
  end

  # Write `id`'s record with extent {start, stop} under `parent` in tree `root`,
  # index it, then carve + recurse into its children. A template element's content
  # DocumentFragment is a DETACHED subtree (linked via `content`, not `children`),
  # so it is materialized as its own root (parent nil, full window) after the
  # element itself.
  defp load_node(tree, tid, index, id, root, parent, start, stop) do
    write_record(tree, tid, index, id, root, parent, start, stop)

    kids = children(tree, id)

    carve_children(kids, start, stop)
    |> Enum.each(fn {kid, {cstart, cstop}} ->
      load_node(tree, tid, index, kid, root, id, cstart, cstop)
    end)

    if content = content(tree, id) do
      load_node(tree, tid, index, content, content, nil, <<0x00>>, <<0x80>>)
    end
  end

  # Pair each child with its extent window inside (start, stop): none for [], a
  # single interval for one child, a multispan partition for many.
  defp carve_children([], _start, _stop), do: []

  defp carve_children([only], start, stop), do: [{only, Table.interval(start, stop)}]

  defp carve_children(kids, start, stop) do
    Enum.zip(kids, Table.multispan(start, stop, length(kids)))
  end

  # Build the DOM.NodeData.* record for `id`, insert it, and index it if element.
  defp write_record(tree, tid, index, id, root, parent, start, stop) do
    data = fetch(tree, id)
    record = to_record(data, parent, root, start, stop)
    :ets.insert(tid, {id, record})

    if data.kind == :element, do: Table.index_put(index, id, record)
    :ok
  end

  defp to_record(%{kind: :element} = d, parent, root, start, stop) do
    %NodeData.Element{
      local_name: d.local_name,
      namespace: d.namespace,
      attributes: d.attributes,
      content: Map.get(d, :content),
      parent: parent,
      root: root,
      start: start,
      stop: stop
    }
  end

  defp to_record(%{kind: :text, value: v}, parent, root, start, stop) do
    %NodeData.Text{value: v, parent: parent, root: root, start: start, stop: stop}
  end

  defp to_record(%{kind: :comment, value: v}, parent, root, start, stop) do
    %NodeData.Comment{value: v, parent: parent, root: root, start: start, stop: stop}
  end

  defp to_record(%{kind: :doctype} = d, parent, root, start, stop) do
    %NodeData.DocumentType{
      name: d.name,
      public_id: d.public_id,
      system_id: d.system_id,
      parent: parent,
      root: root,
      start: start,
      stop: stop
    }
  end

  defp to_record(%{kind: :document}, parent, root, start, stop) do
    %NodeData.Document{parent: parent, root: root, start: start, stop: stop}
  end

  defp to_record(%{kind: :document_fragment}, parent, root, start, stop) do
    %NodeData.DocumentFragment{parent: parent, root: root, start: start, stop: stop}
  end
end
