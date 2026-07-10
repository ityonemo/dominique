defmodule DOM.Range.LiveAdjustTest do
  use DOM.Case, async: true

  # P2: live boundary adjustment. When the tree mutates under a held range, its
  # boundaries adjust per the WHATWG range-mutation rules. DOM.Case's on_exit net
  # (check_ranges!) also proves no boundary is left dangling.

  alias DOM.Node
  alias DOM.Range

  describe "insert shifts offsets after the insertion point" do
    test "inserting a child before the boundary index bumps the offset" do
      doc = new_document("<ul id='u'><li id='a'>a</li><li id='b'>b</li></ul>")
      u = DOM.query_selector(doc, "#u")
      b = DOM.query_selector(doc, "#b")

      # range at (u, 2) — after both li's
      range = Range.create_range(doc) |> Range.set_start(u, 2) |> Range.set_end(u, 2)

      # insert a new li before b (at index 1) -> offset 2 becomes 3
      new_li = DOM.create_element(doc, "li")
      Node.insert_before(u, new_li, b)

      assert Range.start_offset(range) == 3
      assert Range.end_offset(range) == 3
      assert Range.start_container(range).node_id == u.node_id
    end

    test "inserting after the boundary index leaves the offset" do
      doc = new_document("<ul id='u'><li id='a'>a</li><li id='b'>b</li></ul>")
      u = DOM.query_selector(doc, "#u")

      # range at (u, 1) — between a and b
      range = Range.create_range(doc) |> Range.set_start(u, 1) |> Range.set_end(u, 1)

      # append a new li (at the end, index 2) -> offset 1 unaffected
      Node.append_child(u, DOM.create_element(doc, "li"))

      assert Range.start_offset(range) == 1
    end
  end

  describe "remove shifts / relocates boundaries" do
    test "removing a child before the boundary index decrements the offset" do
      doc = new_document("<ul id='u'><li id='a'>a</li><li id='b'>b</li><li id='c'>c</li></ul>")
      u = DOM.query_selector(doc, "#u")
      a = DOM.query_selector(doc, "#a")

      # range at (u, 2)
      range = Range.create_range(doc) |> Range.set_start(u, 2) |> Range.set_end(u, 2)

      # remove a (index 0) -> offset 2 becomes 1
      Node.remove_child(u, a)

      assert Range.start_offset(range) == 1
      assert Range.start_container(range).node_id == u.node_id
    end

    test "removing the boundary's own container subtree relocates it to the parent" do
      doc = new_document("<div id='d'><p id='p'>hello</p><span id='s'>x</span></div>")
      d = DOM.query_selector(doc, "#d")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)

      # range inside p's text (chars 1..3)
      range = Range.create_range(doc) |> Range.set_start(text, 1) |> Range.set_end(text, 3)

      # remove p (index 0 of d) -> both boundaries relocate to (d, 0)
      Node.remove_child(d, p)

      assert Range.start_container(range).node_id == d.node_id
      assert Range.start_offset(range) == 0
      assert Range.end_container(range).node_id == d.node_id
      assert Range.end_offset(range) == 0
    end
  end

  describe "moving a boundary's container follows it (graft)" do
    test "appending the boundary container elsewhere keeps the boundary on it" do
      doc = new_document("<main><div id='src'><p id='p'>x</p></div><div id='dest'></div></main>")
      dest = DOM.query_selector(doc, "#dest")
      p = DOM.query_selector(doc, "#p")

      # a range selecting p's contents (p, 0)..(p, 1)
      range = Range.select_node_contents(Range.create_range(doc), p)
      assert Range.start_container(range).node_id == p.node_id

      # move p into dest (graft: p's extent key is rewritten)
      Node.append_child(dest, p)

      # the boundary still names p (its container followed the graft)
      assert Range.start_container(range).node_id == p.node_id
      assert Range.start_offset(range) == 0
      assert Range.end_offset(range) == 1
    end
  end
end
