defmodule DOM.NodeData.TableTest do
  use ExUnit.Case, async: true

  # DOM.NodeData.Table operates on a bare nodes `tid` keyed by node id, with no
  # GenServer — so these tests build a throwaway ETS table scoped to the test and
  # exercise the primitives directly. This is the same shape the HTML tree builder
  # uses it in.

  alias DOM.NodeData
  alias DOM.NodeData.Table

  setup do
    {:ok, tid: :ets.new(:test_nodes, [:set, :private])}
  end

  # A minimal element record for the index primitives (index_put takes a record).
  defp el(attributes, local_name \\ "div") do
    %NodeData.Element{local_name: local_name, attributes: attributes}
  end

  describe "creation" do
    test "create_element inserts a detached element record", %{tid: tid} do
      id = Table.create_element(tid, "div")

      assert %NodeData.Element{local_name: "div", parent: nil, children: []} =
               Table.fetch!(tid, id)

      assert Table.node_name(tid, id) == "div"
      assert Table.type(tid, id) == :element
    end

    test "create_text / create_comment carry their value", %{tid: tid} do
      t = Table.create_text(tid, "hi")
      c = Table.create_comment(tid, "note")
      assert Table.value(tid, t) == "hi"
      assert Table.node_name(tid, t) == "#text"
      assert Table.node_name(tid, c) == "#comment"
    end

    test "create_template links the content fragment via the content field", %{tid: tid} do
      {template, content} = Table.create_template(tid, [{"id", "x"}])
      assert Table.node_name(tid, template) == "template"
      assert Table.content(tid, template) == content
      assert %NodeData.DocumentFragment{} = Table.fetch!(tid, content)
    end

    test "node_name covers every node kind", %{tid: tid} do
      assert Table.node_name(tid, Table.create_document(tid)) == "#document"
      assert Table.node_name(tid, Table.create_doctype(tid, "html", nil, nil)) == "html"
      {_t, content} = Table.create_template(tid, [])
      assert Table.node_name(tid, content) == "#document-fragment"
    end
  end

  describe "check_consistency! — adjacency integrity" do
    test "passes for a well-formed tree built through the primitives", %{tid: tid} do
      doc = Table.create_document(tid)
      ul = Table.create_element(tid, "ul")
      a = Table.create_element(tid, "a")
      b = Table.create_element(tid, "b")
      Table.append_child(tid, doc, ul)
      Table.append_child(tid, ul, a)
      Table.append_child(tid, ul, b)

      assert Table.check_consistency!(tid) == :ok
    end

    test "passes for a legitimately detached subtree (nil-rooted, self-consistent)", %{tid: tid} do
      # A detached fragment: its root has parent: nil, its internal edges agree.
      frag = Table.create_element(tid, "section")
      child = Table.create_element(tid, "p")
      Table.append_child(tid, frag, child)

      assert Table.check_consistency!(tid) == :ok
    end

    test "passes for a template's content fragment (linked via content, parent nil)", %{tid: tid} do
      {_template, content} = Table.create_template(tid, [{"id", "x"}])
      inner = Table.create_element(tid, "span")
      Table.append_child(tid, content, inner)

      assert Table.check_consistency!(tid) == :ok
    end

    test "raises when a child's parent field is stale (in parent.children but points elsewhere)",
         %{tid: tid} do
      p = Table.create_element(tid, "ul")
      c = Table.create_element(tid, "li")
      Table.append_child(tid, p, c)
      # Corrupt: c is listed under p, but c.parent points at nil.
      Table.put(tid, c, %{Table.fetch!(tid, c) | parent: nil})

      assert_raise RuntimeError, ~r/consisten/i, fn -> Table.check_consistency!(tid) end
    end

    test "raises when a node's parent lists it nowhere (detach-and-forgot leak)", %{tid: tid} do
      p = Table.create_element(tid, "ul")
      c = Table.create_element(tid, "li")
      Table.append_child(tid, p, c)
      # Corrupt: drop c from p.children but leave c.parent == p (a stale detach).
      Table.put(tid, p, %{Table.fetch!(tid, p) | children: []})

      assert_raise RuntimeError, ~r/consisten/i, fn -> Table.check_consistency!(tid) end
    end

    test "raises when a child appears twice in parent.children", %{tid: tid} do
      p = Table.create_element(tid, "ul")
      c = Table.create_element(tid, "li")
      Table.append_child(tid, p, c)
      # Corrupt: duplicate the child in the list.
      Table.put(tid, p, %{Table.fetch!(tid, p) | children: [c, c]})

      assert_raise RuntimeError, ~r/consisten/i, fn -> Table.check_consistency!(tid) end
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
      a = Table.create_element(tid, "a")
      Table.set_attribute(tid, a, "id", "one")
      Table.index_put(index, a, Table.fetch!(tid, a))

      assert Table.check_consistency!(tid, index) == :ok
    end

    test "raises when an element's id is missing from the index", %{tid: tid, index: index} do
      a = Table.create_element(tid, "a")
      Table.set_attribute(tid, a, "id", "one")
      # index intentionally NOT updated

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "raises when the index points at a node with no such id (stale row)",
         %{tid: tid, index: index} do
      a = Table.create_element(tid, "a")
      Table.index_put(index, a, el([{"id", "ghost"}], "a"))

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "raises when the index points at a deleted node", %{tid: tid, index: index} do
      a = Table.create_element(tid, "a")
      Table.set_attribute(tid, a, "id", "one")
      Table.index_put(index, a, el([{"id", "one"}]))
      :ets.delete(tid, a)

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "passes when the class index mirrors the element rows", %{tid: tid, index: index} do
      a = Table.create_element(tid, "a")
      Table.set_attribute(tid, a, "class", "box highlight")
      Table.index_put(index, a, Table.fetch!(tid, a))

      assert Table.check_consistency!(tid, index) == :ok
    end

    test "raises when an element's class token is missing from the index",
         %{tid: tid, index: index} do
      a = Table.create_element(tid, "a")
      Table.set_attribute(tid, a, "class", "box highlight")
      Table.index_put(index, a, el([{"class", "box"}], "a"))
      # "highlight" token intentionally missing from the index

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "raises when the class index has a stale token", %{tid: tid, index: index} do
      a = Table.create_element(tid, "a")
      Table.set_attribute(tid, a, "class", "box")
      Table.index_put(index, a, el([{"class", "box ghost"}], "a"))

      assert_raise RuntimeError, ~r/index/i, fn -> Table.check_consistency!(tid, index) end
    end
  end

  describe "check_consistency!/2 — span (extent) agreement" do
    setup do
      {:ok, index: :ets.new(:test_index, [:ordered_set, :private])}
    end

    # Build a root with two children, extent-labeling every node and writing its
    # span rows + keeping the `children` field in sync. Root extent is the fixed
    # <<0x00>>..<<0x80>>; children get nested extents inside it.
    defp extent_tree(tid, index) do
      root = Table.create_document(tid)
      a = Table.create_element(tid, "a")
      b = Table.create_element(tid, "b")

      label = fn id, parent, root_id, start, stop, kids ->
        rec = Table.fetch!(tid, id)
        rec = %{rec | parent: parent, root: root_id, start: start, stop: stop, children: kids}
        Table.put(tid, id, rec)
        Table.span_put(index, id, %{root: root_id, parent: parent, start: start, stop: stop})
        id
      end

      label.(root, nil, root, <<0x00>>, <<0x80>>, [a, b])
      label.(a, root, root, <<0x10>>, <<0x20>>, [])
      label.(b, root, root, <<0x30>>, <<0x40>>, [])
      # register the element membership rows too (a real tree has both)
      Table.index_put(index, a, Table.fetch!(tid, a))
      Table.index_put(index, b, Table.fetch!(tid, b))
      %{root: root, a: a, b: b}
    end

    test "passes for a well-formed extent-labeled tree", %{tid: tid, index: index} do
      extent_tree(tid, index)
      assert Table.check_consistency!(tid, index) == :ok
    end

    test "raises when a child's extent is not contained in its parent's",
         %{tid: tid, index: index} do
      %{a: a} = extent_tree(tid, index)
      # push a's stop past the root's stop (0x80) — containment broken
      rec = Table.fetch!(tid, a)
      Table.span_retract(index, a)
      rec = %{rec | stop: <<0x90>>}
      Table.put(tid, a, rec)
      Table.span_put(index, a, Map.take(rec, [:root, :parent, :start, :stop]))

      assert_raise RuntimeError, ~r/containment/i, fn -> Table.check_consistency!(tid, index) end
    end

    test "raises when span-derived children disagree with the children field",
         %{tid: tid, index: index} do
      %{b: b} = extent_tree(tid, index)
      # drop b's span row but keep it in the field + its node row (parent intact),
      # so field adjacency still holds but the span-derived child list is missing b
      Table.span_retract(index, b)

      assert_raise RuntimeError, ~r/disagree/i, fn ->
        Table.check_consistency!(tid, index)
      end
    end

    test "raises on a dangling span row (points at a non-existent node)",
         %{tid: tid, index: index} do
      %{root: root} = extent_tree(tid, index)
      ghost = make_ref()
      # a span row whose node_id has no nodes-table row; field adjacency untouched
      Table.span_put(index, ghost, %{root: root, parent: root, start: <<0x50>>, stop: <<0x60>>})

      assert_raise RuntimeError, ~r/dangling span/i, fn ->
        Table.check_consistency!(tid, index)
      end
    end
  end

  describe "mutation" do
    test "append_child links parent and child both ways", %{tid: tid} do
      p = Table.create_element(tid, "ul")
      c = Table.create_element(tid, "li")
      Table.append_child(tid, p, c)
      assert Table.children(tid, p) == [c]
      assert Table.parent(tid, c) == p
    end

    test "append_child preserves order", %{tid: tid} do
      p = Table.create_element(tid, "ul")
      a = Table.create_element(tid, "a")
      b = Table.create_element(tid, "b")
      Table.append_child(tid, p, a)
      Table.append_child(tid, p, b)
      assert Table.children(tid, p) == [a, b]
    end

    test "append_child MOVES a node that already has a parent (detach first)", %{tid: tid} do
      old = Table.create_element(tid, "old")
      new = Table.create_element(tid, "new")
      c = Table.create_element(tid, "c")
      Table.append_child(tid, old, c)
      Table.append_child(tid, new, c)
      assert Table.children(tid, old) == []
      assert Table.children(tid, new) == [c]
      assert Table.parent(tid, c) == new
    end

    test "insert_before splices immediately before the reference", %{tid: tid} do
      p = Table.create_element(tid, "p")
      a = Table.create_element(tid, "a")
      b = Table.create_element(tid, "b")
      x = Table.create_element(tid, "x")
      Table.append_child(tid, p, a)
      Table.append_child(tid, p, b)
      Table.insert_before(tid, p, x, b)
      assert Table.children(tid, p) == [a, x, b]
      assert Table.parent(tid, x) == p
    end

    test "remove_child unlinks both ways", %{tid: tid} do
      p = Table.create_element(tid, "p")
      c = Table.create_element(tid, "c")
      Table.append_child(tid, p, c)
      Table.remove_child(tid, p, c)
      assert Table.children(tid, p) == []
      assert Table.parent(tid, c) == nil
    end
  end

  describe "attributes" do
    test "set / get / has, first-wins keystore", %{tid: tid} do
      el = Table.create_element(tid, "div")
      refute Table.has_attribute(tid, el, "a")
      Table.set_attribute(tid, el, "a", "1")
      assert Table.has_attribute(tid, el, "a")
      assert Table.get_attribute(tid, el, "a") == "1"
    end

    test "put_attribute_if_absent keeps the existing value", %{tid: tid} do
      el = Table.create_element(tid, "div")
      Table.set_attribute(tid, el, "a", "1")
      Table.put_attribute_if_absent(tid, el, "a", "2")
      assert Table.get_attribute(tid, el, "a") == "1"
      Table.put_attribute_if_absent(tid, el, "b", "2")
      assert Table.get_attribute(tid, el, "b") == "2"
    end
  end

  describe "clone" do
    test "shallow clone is a detached leaf copy", %{tid: tid} do
      el = Table.create_element(tid, "div")
      Table.set_attribute(tid, el, "a", "1")
      Table.append_child(tid, el, Table.create_text(tid, "x"))
      clone = Table.clone(tid, el, false)
      assert Table.node_name(tid, clone) == "div"
      assert Table.get_attribute(tid, clone, "a") == "1"
      assert Table.children(tid, clone) == []
      assert Table.parent(tid, clone) == nil
    end

    test "deep clone copies the subtree with reparented children", %{tid: tid} do
      el = Table.create_element(tid, "div")
      inner = Table.create_element(tid, "span")
      Table.append_child(tid, el, inner)
      Table.append_child(tid, inner, Table.create_text(tid, "x"))
      clone = Table.clone(tid, el, true)
      [clone_span] = Table.children(tid, clone)
      assert clone_span != inner
      assert Table.node_name(tid, clone_span) == "span"
      assert Table.parent(tid, clone_span) == clone
      assert [t] = Table.children(tid, clone_span)
      assert Table.value(tid, t) == "x"
    end
  end

  describe "queries" do
    test "descendant_ids / elements_by_tag_name in tree order", %{tid: tid} do
      root = Table.create_element(tid, "div")
      a = Table.create_element(tid, "a")
      b = Table.create_element(tid, "b")
      a2 = Table.create_element(tid, "a")
      Table.append_child(tid, root, a)
      Table.append_child(tid, a, b)
      Table.append_child(tid, root, a2)
      assert Table.descendant_ids(tid, root) == [a, b, a2]
      assert Table.elements_by_tag_name(tid, root, "a") == [a, a2]
      assert Table.elements_by_tag_name(tid, root, "*") == [a, b, a2]
    end
  end
end
