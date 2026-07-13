defmodule DOM.HTML.TreeBuilder.TreeTest do
  use ExUnit.Case, async: true

  # The in-memory parse tree the HTML tree builder mutates during construction
  # (plain Elixir data, no ETS), then bulk-loads into the real node table +
  # index at EOF via multispan. These tests exercise the mutable ops and the
  # bulk load in isolation, without running a full parse.

  alias DOM.HTML.TreeBuilder.Tree
  alias DOM.NodeData
  alias DOM.NodeData.Table

  describe "mutable tree ops (no ETS)" do
    test "new/1 seeds a document root; append_child links parent + order" do
      {tree, doc} = Tree.new_document()
      {tree, a} = Tree.create_element(tree, "a")
      {tree, b} = Tree.create_element(tree, "b")
      tree = tree |> Tree.append_child(doc, a) |> Tree.append_child(doc, b)

      assert Tree.children(tree, doc) == [a, b]
      assert Tree.parent(tree, a) == doc
      assert Tree.node_name(tree, a) == "a"
    end

    test "insert_before splices immediately before the reference" do
      {tree, doc} = Tree.new_document()
      {tree, a} = Tree.create_element(tree, "a")
      {tree, b} = Tree.create_element(tree, "b")
      {tree, x} = Tree.create_element(tree, "x")
      tree = tree |> Tree.append_child(doc, a) |> Tree.append_child(doc, b)
      tree = Tree.insert_before(tree, doc, x, b)

      assert Tree.children(tree, doc) == [a, x, b]
      assert Tree.parent(tree, x) == doc
    end

    test "append_child MOVES a node that already has a parent (detach first)" do
      {tree, doc} = Tree.new_document()
      {tree, old} = Tree.create_element(tree, "old")
      {tree, new} = Tree.create_element(tree, "new")
      {tree, c} = Tree.create_element(tree, "c")
      tree = tree |> Tree.append_child(doc, old) |> Tree.append_child(doc, new)
      tree = Tree.append_child(tree, old, c)
      tree = Tree.append_child(tree, new, c)

      assert Tree.children(tree, old) == []
      assert Tree.children(tree, new) == [c]
      assert Tree.parent(tree, c) == new
    end

    test "remove_child unlinks (child keeps its subtree, parent nil)" do
      {tree, doc} = Tree.new_document()
      {tree, a} = Tree.create_element(tree, "a")
      tree = Tree.append_child(tree, doc, a)
      tree = Tree.remove_child(tree, doc, a)

      assert Tree.children(tree, doc) == []
      assert Tree.parent(tree, a) == nil
    end

    test "text nodes carry a value that set_value mutates (coalescing)" do
      {tree, doc} = Tree.new_document()
      {tree, t} = Tree.create_text(tree, "ab")
      tree = Tree.append_child(tree, doc, t)
      assert Tree.node_type(tree, t) == :text
      assert Tree.value(tree, t) == "ab"
      tree = Tree.set_value(tree, t, "abcd")
      assert Tree.value(tree, t) == "abcd"
    end

    test "attributes: set / get / has (first-wins), used by merge_attributes" do
      {tree, _doc} = Tree.new_document()
      {tree, el} = Tree.create_element(tree, "div")
      refute Tree.has_attribute(tree, el, "id")
      tree = Tree.set_attribute(tree, el, "id", "x")
      assert Tree.has_attribute(tree, el, "id")
      assert Tree.get_attribute(tree, el, "id") == "x"
    end

    test "create_template links the content fragment via content" do
      {tree, _doc} = Tree.new_document()
      {tree, template, content} = Tree.create_template(tree, [{"id", "t"}])
      assert Tree.node_name(tree, template) == "template"
      assert Tree.content(tree, template) == content
    end
  end

  describe "bulk_load: build the in-memory tree into ETS + index via multispan" do
    setup do
      {:ok,
       tid: :ets.new(:bl_nodes, [:set, :public]),
       index: :ets.new(:bl_index, [:ordered_set, :public])}
    end

    test "loads a small tree; extents encode order; check_consistency! passes",
         %{tid: tid, index: index} do
      # doc -> ul -> [a, b -> [c]]
      {tree, doc} = Tree.new_document()
      {tree, ul} = Tree.create_element(tree, "ul")
      {tree, a} = Tree.create_element(tree, "a")
      {tree, b} = Tree.create_element(tree, "b")
      {tree, c} = Tree.create_element(tree, "c")

      tree =
        tree
        |> Tree.append_child(doc, ul)
        |> Tree.append_child(ul, a)
        |> Tree.append_child(ul, b)
        |> Tree.append_child(b, c)

      # doc's id is the pre-inserted document record; bulk_load writes every node.
      :ets.insert(tid, {doc, %NodeData.Document{root: doc, start: <<0x00>>, stop: <<0x80>>}})
      Tree.bulk_load(tree, tid, index, doc)
      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
      assert Table.children_by_extent(tid, doc) == [ul]
      assert Table.children_by_extent(tid, ul) == [a, b]
      assert Table.children_by_extent(tid, b) == [c]
      assert Table.node_name(tid, a) == "a"
    end

    test "loads a wide child list (multispan path) in order",
         %{tid: tid, index: index} do
      {tree, doc} = Tree.new_document()
      {tree, root} = Tree.create_element(tree, "root")
      tree = Tree.append_child(tree, doc, root)

      {tree, kids} =
        Enum.reduce(1..12, {tree, []}, fn i, {tr, acc} ->
          {tr, k} = Tree.create_element(tr, "k#{i}")
          {Tree.append_child(tr, root, k), [k | acc]}
        end)

      kids = Enum.reverse(kids)

      :ets.insert(tid, {doc, %NodeData.Document{root: doc, start: <<0x00>>, stop: <<0x80>>}})
      Tree.bulk_load(tree, tid, index, doc)
      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
      assert Table.children_by_extent(tid, root) == kids
    end

    test "carries element attributes, text values, and namespaces into the records",
         %{tid: tid, index: index} do
      {tree, doc} = Tree.new_document()
      {tree, svg} = Tree.create_element_ns(tree, "svg", :svg, [{"width", "10"}])
      {tree, t} = Tree.create_text(tree, "hi")
      tree = tree |> Tree.append_child(doc, svg) |> Tree.append_child(svg, t)

      :ets.insert(tid, {doc, %NodeData.Document{root: doc, start: <<0x00>>, stop: <<0x80>>}})
      Tree.bulk_load(tree, tid, index, doc)
      Table.span_index_all(tid, index)

      assert Table.get_attribute(tid, svg, "width") == "10"
      assert Table.namespace(tid, svg) == :svg
      assert Table.value(tid, t) == "hi"
      # the svg attribute is indexed too
      assert Table.index_lookup(index, :attr, "width", "10") == [svg]
    end

    test "materializes a template's content fragment (linked via content, not children)",
         %{tid: tid, index: index} do
      # A template's contents live in its content DocumentFragment, reached through
      # the `content` field — NOT the template's children. bulk_load must load that
      # detached fragment (and its subtree) as its own root, else the parsed
      # template contents never reach ETS.
      {tree, doc} = Tree.new_document()
      {tree, template, content} = Tree.create_template(tree, [])
      {tree, inner} = Tree.create_element(tree, "span")
      tree = tree |> Tree.append_child(doc, template) |> Tree.append_child(content, inner)

      :ets.insert(tid, {doc, %NodeData.Document{root: doc, start: <<0x00>>, stop: <<0x80>>}})
      Tree.bulk_load(tree, tid, index, doc)
      Table.span_index_all(tid, index)

      assert Table.check_consistency!(tid, index) == :ok
      # the template is in the document; the fragment is a detached root carrying
      # the parsed content; the fragment's child is materialized.
      assert Table.children_by_extent(tid, doc) == [template]
      assert Table.children_by_extent(tid, template) == []
      assert Table.content(tid, template) == content
      assert Table.children_by_extent(tid, content) == [inner]
      assert Table.node_name(tid, inner) == "span"
    end
  end
end
