defmodule DOM.ReentrancyTest do
  use DOM.Case, async: true

  # Every WHATWG DOM operation must be callable from INSIDE the document server
  # process — the condition an event listener runs under during dispatch. DOM.lambda
  # runs a 0-arity fun in the server (server == self()); if the operation is not
  # re-entrant-safe it would deadlock and time out. Each test asserts the re-entrant
  # result equals the ordinary (external) call, so we prove both "no deadlock" and
  # "same answer".

  alias DOM.Element
  alias DOM.Node

  # Run `fun` inside `node`'s server and return its value.
  defp inside(node, fun), do: DOM.lambda(node.server, fun)

  describe "reads" do
    test "get_attribute / has_attribute / get_attribute_names" do
      doc = new_document("<div id='x' class='a b'>hi</div>")
      el = DOM.query_selector(doc, "#x")

      assert inside(el, fn -> Element.get_attribute(el, "id") end) == "x"
      assert inside(el, fn -> Element.has_attribute(el, "class") end)
      assert inside(el, fn -> Element.get_attribute_names(el) end) == ["id", "class"]
    end

    test "local_name / namespace" do
      doc = new_document("<section id='s'></section>")
      el = DOM.query_selector(doc, "#s")

      assert inside(el, fn -> Element.local_name(el) end) == "section"
      assert inside(el, fn -> Element.namespace(el) end) == :html
    end

    test "node_type / node_name / value / text_content" do
      doc = new_document("<p id='p'>hello</p>")
      p = DOM.query_selector(doc, "#p")

      assert inside(p, fn -> Node.node_type(p) end) == 1
      assert inside(p, fn -> Node.node_name(p) end) == "p"
      assert inside(p, fn -> Node.text_content(p) end) == "hello"
    end
  end

  describe "tree queries" do
    setup do
      doc =
        new_document("""
        <main><div id='a' class='k'></div><span class='k'></span><div id='b'></div></main>
        """)

      %{doc: doc}
    end

    test "get_element_by_id", %{doc: doc} do
      expected = DOM.get_element_by_id(doc, "a")
      assert inside(doc, fn -> DOM.get_element_by_id(doc, "a") end).node_id == expected.node_id
    end

    test "get_elements_by_tag_name", %{doc: doc} do
      expected = DOM.get_elements_by_tag_name(doc, "div") |> Enum.map(& &1.node_id)
      actual = inside(doc, fn -> DOM.get_elements_by_tag_name(doc, "div") end)
      assert Enum.map(actual, & &1.node_id) == expected
    end

    test "get_elements_by_class_name", %{doc: doc} do
      expected = DOM.get_elements_by_class_name(doc, "k") |> Enum.map(& &1.node_id)
      actual = inside(doc, fn -> DOM.get_elements_by_class_name(doc, "k") end)
      assert Enum.map(actual, & &1.node_id) == expected
    end

    test "query_selector / query_selector_all", %{doc: doc} do
      expected_one = DOM.query_selector(doc, ".k")
      assert inside(doc, fn -> DOM.query_selector(doc, ".k") end).node_id == expected_one.node_id

      expected_all = DOM.query_selector_all(doc, "div") |> Enum.map(& &1.node_id)
      actual = inside(doc, fn -> DOM.query_selector_all(doc, "div") end)
      assert Enum.map(actual, & &1.node_id) == expected_all
    end

    test "matches", %{doc: doc} do
      a = DOM.get_element_by_id(doc, "a")
      assert inside(a, fn -> DOM.matches(a, "div.k") end)
      refute inside(a, fn -> DOM.matches(a, "span") end)
    end
  end

  describe "serialization + document reads" do
    test "inner_html / outer_html" do
      doc = new_document("<div id='d'><b>x</b></div>")
      d = DOM.query_selector(doc, "#d")

      assert inside(d, fn -> Element.inner_html(d) end) == "<b>x</b>"
      assert inside(d, fn -> Element.outer_html(d) end) == ~s(<div id="d"><b>x</b></div>)
    end

    test "owner_document" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      assert inside(d, fn -> Node.owner_document(d) end).node_id == doc.node_id
      # the document's own owner_document is nil
      assert inside(doc, fn -> Node.owner_document(doc) end) == nil
    end

    test "clone_node" do
      doc = new_document("<div id='d'><span>x</span></div>")
      d = DOM.query_selector(doc, "#d")

      clone = inside(d, fn -> Node.clone_node(d, true) end)
      assert clone.node_id != d.node_id
      assert Element.outer_html(clone) == ~s(<div id="d"><span>x</span></div>)
    end

    test "get_root_node" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")
      assert inside(d, fn -> Node.get_root_node(d) end).node_id == doc.node_id
    end
  end

  describe "mutations" do
    test "create_element + append_child" do
      doc = new_document("<div id='p'></div>")
      p = DOM.query_selector(doc, "#p")

      inside(doc, fn ->
        child = DOM.create_element(doc, "span")
        Node.append_child(p, child)
      end)

      assert Element.inner_html(p) == "<span></span>"
    end

    test "set_attribute / remove_attribute" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      inside(d, fn -> Element.set_attribute(d, "data-x", "1") end)
      assert Element.get_attribute(d, "data-x") == "1"

      inside(d, fn -> Element.remove_attribute(d, "data-x") end)
      refute Element.has_attribute(d, "data-x")
    end

    test "insert_before / remove_child / replace_child" do
      doc = new_document("<ul id='u'><li id='a'></li><li id='b'></li></ul>")
      u = DOM.query_selector(doc, "#u")
      b = DOM.query_selector(doc, "#b")

      inside(doc, fn ->
        c = DOM.create_element(doc, "li")
        Element.set_attribute(c, "id", "c")
        Node.insert_before(u, c, b)
      end)

      assert Enum.map(DOM.query_selector_all(u, "li"), &Element.get_attribute(&1, "id")) ==
               ["a", "c", "b"]

      a = DOM.query_selector(doc, "#a")
      inside(u, fn -> Node.remove_child(u, a) end)
      refute DOM.query_selector(doc, "#a")

      new = DOM.create_element(doc, "li")
      inside(u, fn -> Node.replace_child(u, new, b) end)
      refute DOM.query_selector(doc, "#b")
    end

    test "set_inner_html / set_text_content" do
      doc = new_document("<div id='d'></div>")
      d = DOM.query_selector(doc, "#d")

      inside(d, fn -> Element.set_inner_html(d, "<b>x</b>") end)
      assert Element.inner_html(d) == "<b>x</b>"

      inside(d, fn -> Node.set_text_content(d, "plain") end)
      assert Node.text_content(d) == "plain"
    end

    test "split_text" do
      doc = new_document("<p id='p'>hello world</p>")
      p = DOM.query_selector(doc, "#p")
      [text] = DOM.Node.child_nodes(p)

      tail = inside(text, fn -> DOM.Text.split_text(text, 5) end)
      assert Node.value(text) == "hello"
      assert Node.value(tail) == " world"
    end
  end

  describe "range surgery (on an existing range)" do
    # A range is created OUTSIDE the server (an external owner is required); its
    # surgery ops are then exercised from inside the server, as a listener would.
    setup do
      doc = new_document("<div id='d'>hello world</div>")
      d = DOM.query_selector(doc, "#d")
      [text] = DOM.Node.child_nodes(d)
      range = DOM.Range.create_range(doc)
      range = DOM.Range.set_start(range, text, 0)
      range = DOM.Range.set_end(range, text, 5)
      %{doc: doc, d: d, text: text, range: range}
    end

    test "clone_contents", %{doc: doc, range: range} do
      frag = inside(doc, fn -> DOM.Range.clone_contents(range) end)
      assert Node.text_content(frag) == "hello"
    end

    test "extract_contents", %{doc: doc, d: d, range: range} do
      frag = inside(doc, fn -> DOM.Range.extract_contents(range) end)
      assert Node.text_content(frag) == "hello"
      assert Node.text_content(d) == " world"
    end

    test "delete_contents", %{doc: doc, d: d, range: range} do
      inside(doc, fn -> DOM.Range.delete_contents(range) end)
      assert Node.text_content(d) == " world"
    end

    test "insert_node", %{doc: doc, d: d, range: range} do
      inside(doc, fn ->
        img = DOM.create_element(doc, "img")
        DOM.Range.insert_node(range, img)
      end)

      assert Element.inner_html(d) =~ "<img>"
    end
  end

  describe "escape hatch: range creation is prohibited inside a listener" do
    # Creating a range needs an EXTERNAL owner to monitor; the server cannot own one
    # (owner == server is rejected). Attempting it from inside the server raises the
    # guard's ArgumentError, which surfaces as the DOM.lambda call exiting with it —
    # i.e. range creation is unavailable to a listener, by design.
    test "create_range is rejected when attempted inside the server" do
      # Use a standalone server we tear down ourselves: this test intentionally
      # crashes the DOM (the guard raises inside the listener), so it must not use
      # the DOM.Case consistency net (which would try to interrogate a dead server).
      Process.flag(:trap_exit, true)
      document_id = make_ref()
      {:ok, server} = GenServer.start(DOM, document_id: document_id)
      doc = %DOM.Node{server: server, node_id: document_id, type: :document}

      # GenServer.call exit: {{exception, exception_stack}, call_info}
      {{exception, _exc_stack}, _call_info} =
        catch_exit(inside(doc, fn -> DOM.Range.create_range(doc) end))

      assert %ArgumentError{message: message} = exception
      assert message =~ "may not be owned by the document server process"
    end
  end

  describe "shadow reads" do
    test "shadow_root / shadow_host / inner_html" do
      doc = new_document("<div id='h'></div>")
      host = DOM.query_selector(doc, "#h")
      s = Element.attach_shadow(host, :open)
      DOM.ShadowRoot.set_inner_html(s, "<p>x</p>")

      assert inside(host, fn -> Element.shadow_root(host) end).node_id == s.node_id
      assert inside(s, fn -> DOM.ShadowRoot.host(s) end).node_id == host.node_id
      assert inside(s, fn -> DOM.ShadowRoot.inner_html(s) end) == "<p>x</p>"
    end

    test "assigned_nodes / assigned_slot" do
      doc = new_document("<div id='h'><a slot='x'>1</a></div>")
      host = DOM.query_selector(doc, "#h")
      s = Element.attach_shadow(host, :open)
      DOM.ShadowRoot.set_inner_html(s, "<slot name='x'></slot>")
      [slot] = DOM.query_selector_all(s, "slot")
      a = DOM.query_selector(doc, "a")

      assigned = inside(slot, fn -> DOM.Slot.assigned_nodes(slot) end)
      assert Enum.map(assigned, & &1.node_id) == [a.node_id]
      assert inside(a, fn -> Node.assigned_slot(a) end).node_id == slot.node_id
    end
  end
end
