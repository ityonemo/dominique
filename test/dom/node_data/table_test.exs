defmodule DOM.NodeData.TableTest do
  use ExUnit.Case, async: true

  # DOM.NodeData.Table operates on a bare nodes `tid` keyed by node id, with no
  # GenServer — so these tests build a throwaway ETS table scoped to the test and
  # exercise the primitives directly. This is the same shape the HTML tree builder
  # uses it in.

  alias DOM.NodeData
  alias DOM.NodeData.Table

  setup do
    {:ok,
     tid: :ets.new(:test_nodes, [:set, :private]),
     index: :ets.new(:test_index, [:ordered_set, :private])}
  end

  # A minimal element record for the index primitives (index_put takes a record).
  defp el(attributes, local_name \\ "div") do
    ref = make_ref()

    %NodeData.Element{
      local_name: local_name,
      attributes: attributes,
      root: ref,
      start: <<0>>,
      stop: <<0x80>>
    }
  end

  describe "creation" do
    test "create_element inserts a detached, labeled 1-node tree record", %{
      tid: tid,
      index: index
    } do
      id = Table.create_element(tid, index, "div")

      # a node is labeled from birth: parentless (parent nil) but its own tree root
      # (root == self), with the fixed root-window extent seeded.
      assert %NodeData.Element{
               local_name: "div",
               parent: nil,
               root: ^id,
               start: <<0x00>>,
               stop: <<0x80>>
             } =
               Table.fetch!(tid, id)

      assert Table.node_name(tid, id) == "div"
      assert Table.type(tid, id) == :element
    end

    test "create_text / create_comment carry their value", %{tid: tid, index: index} do
      t = Table.create_text(tid, index, "hi")
      c = Table.create_comment(tid, index, "note")
      assert Table.value(tid, t) == "hi"
      assert Table.node_name(tid, t) == "#text"
      assert Table.node_name(tid, c) == "#comment"
    end

    test "create_template links the content fragment via the content field", %{
      tid: tid,
      index: index
    } do
      {template, content} = Table.create_template(tid, index, [{"id", "x"}])
      assert Table.node_name(tid, template) == "template"
      assert Table.content(tid, template) == content
      assert %NodeData.DocumentFragment{} = Table.fetch!(tid, content)
    end

    test "node_name covers every node kind", %{tid: tid, index: index} do
      assert Table.node_name(tid, Table.create_document(tid, index)) == "#document"
      assert Table.node_name(tid, Table.create_doctype(tid, index, "html", nil, nil)) == "html"
      {_t, content} = Table.create_template(tid, index, [])
      assert Table.node_name(tid, content) == "#document-fragment"
    end
  end

  describe "check_consistency! — adjacency integrity (extent/span borne)" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    # Adjacency is now the nested-set extents mirrored into span rows; the checker
    # needs the index. Build via the extent-authoritative mutators, sync spans.
    defp synced_tree(tid, index) do
      doc = Table.create_document(tid, index)
      ul = Table.create_element(tid, index, "ul")
      a = Table.create_element(tid, index, "a")
      b = Table.create_element(tid, index, "b")
      Table.append_child(tid, doc, ul)
      Table.append_child(tid, ul, a)
      Table.append_child(tid, ul, b)
      # mirror span + id/class index rows for the built tree in one subtree walk.
      Table.span_index_all(tid, index)
      %{doc: doc, ul: ul, a: a, b: b}
    end

    test "passes for a well-formed extent-labeled tree", %{tid: tid, index: index} do
      synced_tree(tid, index)
      assert Table.check_consistency!(tid, index) == :ok
    end

    test "passes for a legitimately detached subtree (nil-rooted, self-consistent)",
         %{tid: tid, index: index} do
      frag = Table.create_element(tid, index, "section")
      child = Table.create_element(tid, index, "p")
      Table.append_child(tid, frag, child)
      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
    end

    test "raises when a span row is stale (extent moved but span not resynced)",
         %{tid: tid, index: index} do
      ids = synced_tree(tid, index)
      # Corrupt: shift b's extent on the record without re-mirroring the span rows.
      b = Table.fetch!(tid, ids.b)
      Table.put(tid, ids.b, %{b | start: <<0x7A>>, stop: <<0x7B>>})

      assert_raise RuntimeError, ~r/span rows disagree/i, fn ->
        Table.check_consistency!(tid, index)
      end
    end

    test "raises on extent containment violation (child extent outside parent's)",
         %{tid: tid, index: index} do
      ids = synced_tree(tid, index)
      # Corrupt: push a's extent outside ul's window, and resync spans so the mirror
      # check passes and the containment check is the one that fires.
      a = Table.fetch!(tid, ids.a)
      Table.put(tid, ids.a, %{a | start: <<0x7E>>, stop: <<0x7F>>})
      Table.span_index_all(tid, index)

      assert_raise RuntimeError, ~r/containment/i, fn ->
        Table.check_consistency!(tid, index)
      end
    end

    test "raises on a dangling span row (points at a non-existent node)",
         %{tid: tid, index: index} do
      ids = synced_tree(tid, index)
      ghost = make_ref()
      # A span row whose node_id has no nodes-table row (index membership untouched,
      # so the span-backward check is what fires).
      Table.span_put(index, ghost, %{
        root: ids.doc,
        parent: ids.ul,
        start: <<0x50>>,
        stop: <<0x60>>,
        type: :element
      })

      assert_raise RuntimeError, ~r/dangling span/i, fn ->
        Table.check_consistency!(tid, index)
      end
    end
  end

  describe "id index primitives" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    test "index_put registers a node's id; index_lookup finds it", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"id", "foo"}]))
      assert Table.index_lookup(index, :id, "foo") == [node]
      assert Table.index_lookup(index, :id, "absent") == []
    end

    test "index_lookup returns all nodes sharing an id value (duplicates allowed)",
         %{index: index} do
      a = make_ref()
      b = make_ref()
      Table.index_put(index, a, el([{"id", "dup"}]))
      Table.index_put(index, b, el([{"id", "dup"}]))
      assert Enum.sort(Table.index_lookup(index, :id, "dup")) == Enum.sort([a, b])
    end

    test "index_put is an idempotent refresh — re-put with a new id replaces the old",
         %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"id", "old"}]))
      Table.index_put(index, node, el([{"id", "new"}]))
      assert Table.index_lookup(index, :id, "old") == []
      assert Table.index_lookup(index, :id, "new") == [node]
    end

    test "index_put with no id attribute leaves the node unindexed", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"class", "x"}]))
      assert Table.index_lookup(index, :id, "x") == []
    end

    test "index_retract removes a node's id rows", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"id", "foo"}]))
      Table.index_retract(index, node)
      assert Table.index_lookup(index, :id, "foo") == []
    end
  end

  describe "class index primitives" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    test "index_put registers each class token; index_lookup finds them", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"class", "box highlight"}]))
      assert Table.index_lookup(index, :class, "box") == [node]
      assert Table.index_lookup(index, :class, "highlight") == [node]
      assert Table.index_lookup(index, :class, "absent") == []
    end

    test "a class token maps to every node carrying it", %{index: index} do
      a = make_ref()
      b = make_ref()
      Table.index_put(index, a, el([{"class", "box"}], "a"))
      Table.index_put(index, b, el([{"class", "box other"}]))
      assert Enum.sort(Table.index_lookup(index, :class, "box")) == Enum.sort([a, b])
    end

    test "duplicate class tokens are deduped to one row per (node, token)", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"class", "x x x"}]))
      assert Table.index_lookup(index, :class, "x") == [node]
    end

    test "index_put refreshes class rows on change", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"class", "old"}]))
      Table.index_put(index, node, el([{"class", "new"}]))
      assert Table.index_lookup(index, :class, "old") == []
      assert Table.index_lookup(index, :class, "new") == [node]
    end

    test "index_retract removes a node's class rows too", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"id", "i"}, {"class", "a b"}]))
      Table.index_retract(index, node)
      assert Table.index_lookup(index, :class, "a") == []
      assert Table.index_lookup(index, :class, "b") == []
      assert Table.index_lookup(index, :id, "i") == []
    end
  end

  describe "tag index primitives" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    test "index_put registers a node's tag (local_name)", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([], "section"))
      assert Table.index_lookup(index, :tag, "section") == [node]
      assert Table.index_lookup(index, :tag, "div") == []
    end

    test "a tag maps to every element with that local_name", %{index: index} do
      a = make_ref()
      b = make_ref()
      Table.index_put(index, a, el([], "li"))
      Table.index_put(index, b, el([], "li"))
      assert Enum.sort(Table.index_lookup(index, :tag, "li")) == Enum.sort([a, b])
    end

    test "index_retract removes a node's tag row", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"id", "i"}], "span"))
      Table.index_retract(index, node)
      assert Table.index_lookup(index, :tag, "span") == []
      assert Table.index_lookup(index, :id, "i") == []
    end

    test "the tag membership coexists with id/class rows", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"id", "i"}, {"class", "c"}], "p"))
      assert Table.index_lookup(index, :tag, "p") == [node]
      assert Table.index_lookup(index, :id, "i") == [node]
      assert Table.index_lookup(index, :class, "c") == [node]
    end
  end

  describe "attribute index primitives" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    test "index_put registers each attribute; exact lookup finds by name+value",
         %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"data-role", "nav"}, {"title", "Home"}]))
      assert Table.index_lookup(index, :attr, "data-role", "nav") == [node]
      assert Table.index_lookup(index, :attr, "title", "Home") == [node]
      assert Table.index_lookup(index, :attr, "data-role", "other") == []
      assert Table.index_lookup(index, :attr, "absent", "x") == []
    end

    test "by-name lookup returns {value, node} for every value under that name",
         %{index: index} do
      a = make_ref()
      b = make_ref()
      Table.index_put(index, a, el([{"data-x", "1"}]))
      Table.index_put(index, b, el([{"data-x", "2"}]))

      assert Enum.sort(Table.index_lookup_attr_name(index, "data-x")) ==
               Enum.sort([{"1", a}, {"2", b}])

      assert Table.index_lookup_attr_name(index, "absent") == []
    end

    test "id and class are ALSO indexed as attributes", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"id", "main"}, {"class", "box hi"}]))
      # attribute-selector forms read the attr index directly
      assert Table.index_lookup(index, :attr, "id", "main") == [node]
      assert Table.index_lookup(index, :attr, "class", "box hi") == [node]
      # and they still populate the dedicated id/class indices
      assert Table.index_lookup(index, :id, "main") == [node]
      assert Table.index_lookup(index, :class, "box") == [node]
    end

    test "index_retract removes a node's attribute rows", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"data-role", "nav"}]))
      Table.index_retract(index, node)
      assert Table.index_lookup(index, :attr, "data-role", "nav") == []
      assert Table.index_lookup_attr_name(index, "data-role") == []
    end

    test "index_put refreshes attribute rows on change", %{index: index} do
      node = make_ref()
      Table.index_put(index, node, el([{"data-x", "old"}]))
      Table.index_put(index, node, el([{"data-x", "new"}]))
      assert Table.index_lookup(index, :attr, "data-x", "old") == []
      assert Table.index_lookup(index, :attr, "data-x", "new") == [node]
    end
  end

  describe "check_consistency!/2 — id index agreement" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    test "passes when the id index mirrors the element rows", %{tid: tid, index: index} do
      a = Table.create_element(tid, index, "a")
      Table.set_attribute(tid, a, "id", "one")
      Table.index_put(index, a, Table.fetch!(tid, a))
      # the node is labeled from birth — mirror its span rows so the full net passes.
      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
    end

    test "raises when an element's id is missing from the index", %{tid: tid, index: index} do
      a = Table.create_element(tid, index, "a")
      Table.set_attribute(tid, a, "id", "one")
      # index intentionally NOT updated

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "raises when the index points at a node with no such id (stale row)",
         %{tid: tid, index: index} do
      a = Table.create_element(tid, index, "a")
      Table.index_put(index, a, el([{"id", "ghost"}], "a"))

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "raises when the index points at a deleted node", %{tid: tid, index: index} do
      a = Table.create_element(tid, index, "a")
      Table.set_attribute(tid, a, "id", "one")
      Table.index_put(index, a, el([{"id", "one"}]))
      :ets.delete(tid, a)

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "passes when the class index mirrors the element rows", %{tid: tid, index: index} do
      a = Table.create_element(tid, index, "a")
      Table.set_attribute(tid, a, "class", "box highlight")
      Table.index_put(index, a, Table.fetch!(tid, a))
      # the node is labeled from birth — mirror its span rows so the full net passes.
      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
    end

    test "raises when an element's class token is missing from the index",
         %{tid: tid, index: index} do
      a = Table.create_element(tid, index, "a")
      Table.set_attribute(tid, a, "class", "box highlight")
      Table.index_put(index, a, el([{"class", "box"}], "a"))
      # "highlight" token intentionally missing from the index

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "raises when the class index has a stale token", %{tid: tid, index: index} do
      a = Table.create_element(tid, index, "a")
      Table.set_attribute(tid, a, "class", "box")
      Table.index_put(index, a, el([{"class", "box ghost"}], "a"))

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end
  end

  describe "span_index_all + span_children_of (spans mirror the extents the mutators wrote)" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    # Build a tree via the extent-authoritative mutators (which write start/stop
    # live), no index yet.
    defp field_tree(tid, index) do
      root = Table.create_document(tid, index)
      ul = Table.create_element(tid, index, "ul")
      a = Table.create_element(tid, index, "a")
      b = Table.create_element(tid, index, "b")
      c = Table.create_element(tid, index, "c")
      Table.append_child(tid, root, ul)
      Table.append_child(tid, ul, a)
      Table.append_child(tid, ul, b)
      Table.append_child(tid, b, c)
      %{root: root, ul: ul, a: a, b: b, c: c}
    end

    test "mirrors extents so check_consistency! passes and span reads match",
         %{tid: tid, index: index} do
      ids = field_tree(tid, index)
      # mirror span + membership index rows for the built tree in one subtree walk.
      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
      assert Table.span_children_of(tid, index, ids.root) == [ids.ul]
      assert Table.span_children_of(tid, index, ids.ul) == [ids.a, ids.b]
      assert Table.span_children_of(tid, index, ids.b) == [ids.c]
    end

    test "handles multiple roots (a detached second tree)", %{tid: tid, index: index} do
      ids = field_tree(tid, index)
      # a second, detached root (parent nil) — e.g. a template content fragment
      frag = Table.create_document(tid, index)
      x = Table.create_element(tid, index, "x")
      Table.append_child(tid, frag, x)

      # mirror each root's subtree (span + membership rows).
      Table.span_index_all(tid, index)
      Table.span_index_all(tid, index)
      assert Table.check_consistency!(tid, index) == :ok
      assert Table.span_children_of(tid, index, frag) == [x]
    end
  end

  describe "extent-authoritative mutators (write start/stop as they build, nodes tid alone)" do
    # A tree built via the mutators must be readable by extent order WITHOUT any
    # span_build_all pass — the mutators assign start/stop live, so children_by_extent
    # reflects the field order immediately. This is the tree-builder path (no index).
    test "append_child assigns extents so children_by_extent matches the field", %{
      tid: tid,
      index: index
    } do
      root = Table.create_document(tid, index)
      ul = Table.create_element(tid, index, "ul")
      a = Table.create_element(tid, index, "a")
      b = Table.create_element(tid, index, "b")
      c = Table.create_element(tid, index, "c")
      Table.append_child(tid, root, ul)
      Table.append_child(tid, ul, a)
      Table.append_child(tid, ul, b)
      Table.append_child(tid, b, c)

      # No span_build_all — extents came from the mutators themselves.
      assert Table.children_by_extent(tid, root) == [ul]
      assert Table.children_by_extent(tid, ul) == [a, b]
      assert Table.children_by_extent(tid, b) == [c]
      # and each child's extent is strictly inside its parent's.
      assert extent_inside?(tid, ul, root)
      assert extent_inside?(tid, a, ul)
      assert extent_inside?(tid, b, ul)
      assert extent_inside?(tid, c, b)
    end

    # insert-before extent placement now lives in Table.graft_plan / NodeData.graft_into
    # (the `insert_before` mutator was removed); covered by rehome_test.exs.

    test "append_child MOVES an already-labeled subtree via graft", %{tid: tid, index: index} do
      root = Table.create_document(tid, index)
      old = Table.create_element(tid, index, "old")
      new = Table.create_element(tid, index, "new")
      c = Table.create_element(tid, index, "c")
      gc = Table.create_element(tid, index, "gc")
      Table.append_child(tid, root, old)
      Table.append_child(tid, root, new)
      Table.append_child(tid, old, c)
      Table.append_child(tid, c, gc)

      # move c (which has its own child gc) from old to new
      Table.append_child(tid, new, c)

      assert Table.children_by_extent(tid, old) == []
      assert Table.children_by_extent(tid, new) == [c]
      assert Table.children_by_extent(tid, c) == [gc]
      assert extent_inside?(tid, c, new)
      assert extent_inside?(tid, gc, c)
    end

    # Batch multi-child placement (append_children / insert_children_before) and
    # already-labeled graft-per-window are now delivered by NodeData.graft_into (multispan);
    # the Table-level batch mutators were removed. Covered by rehome_test.exs.
  end

  # Whether child's extent is strictly contained in parent's, from the records.
  defp extent_inside?(tid, child, parent) do
    c = Table.fetch!(tid, child)
    p = Table.fetch!(tid, parent)
    p.start < c.start and c.start < c.stop and c.stop < p.stop
  end

  describe "span_index_all (span rows from record extents, no carve, no field)" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    test "populates span rows straight from the extents the mutators wrote",
         %{tid: tid, index: index} do
      # Build via the extent-authoritative mutators — extents already correct, no
      # span_build carve needed. span_index_all just copies extents -> span rows.
      root = Table.create_document(tid, index)
      ul = Table.create_element(tid, index, "ul")
      a = Table.create_element(tid, index, "a")
      b = Table.create_element(tid, index, "b")
      Table.append_child(tid, root, ul)
      Table.append_child(tid, ul, a)
      Table.append_child(tid, ul, b)

      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
      assert Table.span_children_of(tid, index, root) == [ul]
      assert Table.span_children_of(tid, index, ul) == [a, b]
    end

    test "idempotent — re-running leaves the same span rows", %{tid: tid, index: index} do
      root = Table.create_document(tid, index)
      x = Table.create_element(tid, index, "x")
      Table.append_child(tid, root, x)

      Table.span_index_all(tid, index)
      first = :ets.tab2list(index) |> Enum.sort()
      Table.span_index_all(tid, index)
      assert :ets.tab2list(index) |> Enum.sort() == first
    end
  end

  describe "children_by_extent (order from record extents, nodes tid alone)" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    test "returns children in start-key order, reading only the nodes tid",
         %{tid: tid, index: index} do
      ids = field_tree(tid, index)
      Table.span_index_all(tid, index)

      # Same document order as the span-index read, but derived from the record
      # `start` keys on the nodes tid — no index consulted.
      assert Table.children_by_extent(tid, ids.root) == [ids.ul]
      assert Table.children_by_extent(tid, ids.ul) == [ids.a, ids.b]
      assert Table.children_by_extent(tid, ids.b) == [ids.c]
      assert Table.children_by_extent(tid, ids.a) == []
    end

    test "agrees with span_children_of and the children field for every node",
         %{tid: tid, index: index} do
      ids = field_tree(tid, index)
      Table.span_index_all(tid, index)

      for id <- Map.values(ids) do
        assert Table.children_by_extent(tid, id) == Table.span_children_of(tid, index, id)
        assert Table.children_by_extent(tid, id) == Table.children(tid, id)
      end
    end
  end

  describe "append_child grafts an already-labeled subtree on move" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    test "moving a subtree preserves consistency and its internal structure",
         %{tid: tid, index: index} do
      # root -> [ul -> [a, b -> [c]], target]; move `b`'s subtree under `target`.
      root = Table.create_document(tid, index)
      ul = Table.create_element(tid, index, "ul")
      a = Table.create_element(tid, index, "a")
      b = Table.create_element(tid, index, "b")
      c = Table.create_element(tid, index, "c")
      target = Table.create_element(tid, index, "target")
      Table.append_child(tid, root, ul)
      Table.append_child(tid, ul, a)
      Table.append_child(tid, ul, b)
      Table.append_child(tid, b, c)
      Table.append_child(tid, root, target)

      # append_child(target, b) grafts b's whole ([b, c]) subtree into target,
      # writing the new extents live — no separate graft/carve step.
      Table.append_child(tid, target, b)
      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
      assert Table.span_children_of(tid, index, target) == [b]
      assert Table.span_children_of(tid, index, b) == [c]
      assert Table.span_children_of(tid, index, ul) == [a]
    end
  end

  describe "mutation" do
    test "append_child links parent and child both ways", %{tid: tid, index: index} do
      p = Table.create_element(tid, index, "ul")
      c = Table.create_element(tid, index, "li")
      Table.append_child(tid, p, c)
      assert Table.children(tid, p) == [c]
      assert Table.parent(tid, c) == p
    end

    test "append_child preserves order", %{tid: tid, index: index} do
      p = Table.create_element(tid, index, "ul")
      a = Table.create_element(tid, index, "a")
      b = Table.create_element(tid, index, "b")
      Table.append_child(tid, p, a)
      Table.append_child(tid, p, b)
      assert Table.children(tid, p) == [a, b]
    end

    test "append_child MOVES a node that already has a parent (detach first)", %{
      tid: tid,
      index: index
    } do
      old = Table.create_element(tid, index, "old")
      new = Table.create_element(tid, index, "new")
      c = Table.create_element(tid, index, "c")
      Table.append_child(tid, old, c)
      Table.append_child(tid, new, c)
      assert Table.children(tid, old) == []
      assert Table.children(tid, new) == [c]
      assert Table.parent(tid, c) == new
    end

    # insert-before and remove/detach are exercised through NodeData.graft_into /
    # NodeData.detach (see rehome_test.exs); the Table-level insert_before/remove_child
    # mutators were removed when all callers moved to the unified rehome.
  end

  describe "attributes" do
    test "set / get / has, first-wins keystore", %{tid: tid, index: index} do
      el = Table.create_element(tid, index, "div")
      refute Table.has_attribute(tid, el, "a")
      Table.set_attribute(tid, el, "a", "1")
      assert Table.has_attribute(tid, el, "a")
      assert Table.get_attribute(tid, el, "a") == "1"
    end

    test "put_attribute_if_absent keeps the existing value", %{tid: tid, index: index} do
      el = Table.create_element(tid, index, "div")
      Table.set_attribute(tid, el, "a", "1")
      Table.put_attribute_if_absent(tid, el, "a", "2")
      assert Table.get_attribute(tid, el, "a") == "1"
      Table.put_attribute_if_absent(tid, el, "b", "2")
      assert Table.get_attribute(tid, el, "b") == "2"
    end
  end

  describe "clone" do
    test "shallow clone is a detached leaf copy", %{tid: tid, index: index} do
      el = Table.create_element(tid, index, "div")
      Table.set_attribute(tid, el, "a", "1")
      Table.append_child(tid, el, Table.create_text(tid, index, "x"))
      clone = Table.clone_record(tid, el, false)
      assert Table.node_name(tid, clone) == "div"
      assert Table.get_attribute(tid, clone, "a") == "1"
      assert Table.children(tid, clone) == []
      assert Table.parent(tid, clone) == nil
    end

    test "deep clone copies the subtree with reparented children", %{tid: tid, index: index} do
      el = Table.create_element(tid, index, "div")
      inner = Table.create_element(tid, index, "span")
      Table.append_child(tid, el, inner)
      Table.append_child(tid, inner, Table.create_text(tid, index, "x"))
      clone = Table.clone_record(tid, el, true)
      [clone_span] = Table.children(tid, clone)
      assert clone_span != inner
      assert Table.node_name(tid, clone_span) == "span"
      assert Table.parent(tid, clone_span) == clone
      assert [t] = Table.children(tid, clone_span)
      assert Table.value(tid, t) == "x"
    end
  end

  describe "queries" do
    test "descendant_ids / elements_by_tag_name in tree order", %{tid: tid, index: index} do
      root = Table.create_element(tid, index, "div")
      a = Table.create_element(tid, index, "a")
      b = Table.create_element(tid, index, "b")
      a2 = Table.create_element(tid, index, "a")
      Table.append_child(tid, root, a)
      Table.append_child(tid, a, b)
      Table.append_child(tid, root, a2)
      assert Table.descendant_ids(tid, root) == [a, b, a2]
      assert Table.elements_by_tag_name(tid, root, "a") == [a, a2]
      assert Table.elements_by_tag_name(tid, root, "*") == [a, b, a2]
    end
  end
end
