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
end
