defmodule DOM.RangeTest do
  use DOM.Case, async: true

  # DOM.Range: a contiguous start..end boundary span, server-tracked, with
  # boundaries stored as :range_* rows in the index table. These tests own a live
  # document (DOM.Case arms the consistency net, incl. the new check_ranges! pass).

  alias DOM.Node
  alias DOM.Range

  describe "create_range / boundary reads" do
    test "a fresh range is collapsed at (document, 0)" do
      doc = new_document("<div id='a'><p id='p'>hi</p></div>")
      range = Range.create_range(doc)

      assert Range.collapsed?(range)
      assert Range.start_container(range).node_id == doc.node_id
      assert Range.start_offset(range) == 0
      assert Range.end_container(range).node_id == doc.node_id
      assert Range.end_offset(range) == 0
    end

    test "set_start / set_end position both boundaries and read back" do
      doc = new_document("<div id='a'><p id='p'>hi</p><span id='s'>x</span></div>")
      a = DOM.query_selector(doc, "#a")

      range = Range.create_range(doc)
      range = Range.set_start(range, a, 0)
      range = Range.set_end(range, a, 2)

      assert Range.start_container(range).node_id == a.node_id
      assert Range.start_offset(range) == 0
      assert Range.end_container(range).node_id == a.node_id
      assert Range.end_offset(range) == 2
      refute Range.collapsed?(range)
    end

    test "a set_start past set_end collapses the range to the new point (spec)" do
      doc = new_document("<div id='a'><p>1</p><p>2</p><p>3</p></div>")
      a = DOM.query_selector(doc, "#a")

      range = Range.create_range(doc) |> Range.set_end(a, 1) |> Range.set_start(a, 2)
      # start moved past end -> both collapse to start
      assert Range.start_offset(range) == 2
      assert Range.end_offset(range) == 2
      assert Range.collapsed?(range)
    end

    test "set_start on a text node uses a character offset" do
      doc = new_document("<p id='p'>hello</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)

      range = Range.create_range(doc) |> Range.set_start(text, 1) |> Range.set_end(text, 4)
      assert Range.start_container(range).node_id == text.node_id
      assert Range.start_offset(range) == 1
      assert Range.end_offset(range) == 4
    end

    test "offset past the container's max raises IndexSizeError" do
      doc = new_document("<p id='p'>hi</p>")
      p = DOM.query_selector(doc, "#p")

      # <p> has one child (the text node); offset 2 is out of range for child-index.
      assert_raise DOM.IndexSizeError, fn -> Range.create_range(doc) |> Range.set_start(p, 2) end
    end
  end

  describe "collapse / select_node" do
    test "collapse(true) collapses to the start" do
      doc = new_document("<div id='a'><p>1</p><p>2</p></div>")
      a = DOM.query_selector(doc, "#a")
      range = Range.create_range(doc) |> Range.set_start(a, 0) |> Range.set_end(a, 2)

      range = Range.collapse(range, true)
      assert Range.collapsed?(range)
      assert Range.start_offset(range) == 0
      assert Range.end_offset(range) == 0
    end

    test "collapse(false) collapses to the end" do
      doc = new_document("<div id='a'><p>1</p><p>2</p></div>")
      a = DOM.query_selector(doc, "#a")
      range = Range.create_range(doc) |> Range.set_start(a, 0) |> Range.set_end(a, 2)

      range = Range.collapse(range, false)
      assert Range.collapsed?(range)
      assert Range.start_offset(range) == 2
      assert Range.end_offset(range) == 2
    end

    test "select_node spans the node within its parent" do
      doc = new_document("<div id='a'><p id='p'>x</p><span>y</span></div>")
      a = DOM.query_selector(doc, "#a")
      p = DOM.query_selector(doc, "#p")

      range = Range.select_node(Range.create_range(doc), p)
      # start = before p (child 0 of a), end = after p (child 1 of a)
      assert Range.start_container(range).node_id == a.node_id
      assert Range.start_offset(range) == 0
      assert Range.end_container(range).node_id == a.node_id
      assert Range.end_offset(range) == 1
    end

    test "select_node_contents spans the node's children" do
      doc = new_document("<ul id='u'><li>1</li><li>2</li><li>3</li></ul>")
      u = DOM.query_selector(doc, "#u")

      range = Range.select_node_contents(Range.create_range(doc), u)
      assert Range.start_container(range).node_id == u.node_id
      assert Range.start_offset(range) == 0
      assert Range.end_offset(range) == 3
    end
  end

  describe "compare_boundary_points" do
    setup do
      doc = new_document("<div id='a'><p id='p1'>1</p><p id='p2'>2</p></div>")
      a = DOM.query_selector(doc, "#a")
      %{doc: doc, a: a}
    end

    test "orders two boundaries by document position", %{doc: doc, a: a} do
      r1 = Range.create_range(doc) |> Range.set_start(a, 0) |> Range.set_end(a, 1)
      r2 = Range.create_range(doc) |> Range.set_start(a, 1) |> Range.set_end(a, 2)

      # r1.start before r2.start
      assert Range.compare_boundary_points(r1, :start_to_start, r2) == -1
      # r1.end (1) equals r2.start (1)
      assert Range.compare_boundary_points(r1, :end_to_start, r2) == 0
      # r2.start (1) after r1.start (0)
      assert Range.compare_boundary_points(r2, :start_to_start, r1) == 1
    end
  end

  describe "lifecycle: process-monitor eviction" do
    test "a range owned by a dead process is evicted from the server" do
      doc = new_document("<div id='a'><p>x</p></div>")
      a = DOM.query_selector(doc, "#a")

      # Create a range from a short-lived process, wait for it to die.
      parent = self()

      owner =
        spawn(fn ->
          r = Range.create_range(doc, owner: self()) |> Range.set_start(a, 0)
          send(parent, {:range, r})
          receive do: (:die -> :ok)
        end)

      range = receive do: ({:range, r} -> r)
      assert Range.start_offset(range) == 0

      ref = Process.monitor(owner)
      send(owner, :die)
      receive do: ({:DOWN, ^ref, :process, ^owner, _} -> :ok)

      # After the owner dies the range's rows are gone; using it now fails.
      # (Give the server a beat to process the :DOWN.)
      Process.sleep(20)
      assert Range.detached?(range)
    end

    test "create_range owned by the server process itself is illegal" do
      doc = new_document("<div></div>")
      # A range whose owner resolves to the document server pid must raise.
      assert_raise ArgumentError, fn -> Range.create_range(doc, owner: doc.server) end
    end
  end
end
