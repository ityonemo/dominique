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
