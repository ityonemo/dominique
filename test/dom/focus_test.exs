defmodule DOM.FocusTest do
  use DOM.Case, async: true

  # Focus model: a document-level active element, focus()/blur(), and the :focus /
  # :focus-within / :focus-visible pseudo-classes. Browser-verified semantics in the
  # focus-model-semantics memory. (No focus/blur EVENTS in this arc.)

  alias DOM.Node

  defp id(nil), do: nil
  defp id(%Node{} = n), do: DOM.Element.get_attribute(n, "id") || Node.node_name(n)

  describe "activeElement" do
    test "defaults to <body> when nothing is focused" do
      doc = new_document("<body><input id='i'></body>")
      assert id(DOM.active_element(doc)) == "body"
    end

    test "focus() sets the active element" do
      doc = new_document("<body><input id='i'></body>")
      i = DOM.query_selector(doc, "#i")

      Node.focus(i)
      assert DOM.active_element(doc).node_id == i.node_id
    end

    test "blur() returns focus to <body>" do
      doc = new_document("<body><input id='i'></body>")
      i = DOM.query_selector(doc, "#i")

      Node.focus(i)
      Node.blur(i)
      assert id(DOM.active_element(doc)) == "body"
    end
  end

  describe "focusable" do
    setup do
      doc =
        new_document("""
        <body>
          <a id='a-href' href='#'>a</a><a id='a-bare'>a</a>
          <button id='btn'>b</button><select id='sel'></select>
          <textarea id='ta'></textarea>
          <input id='in'><input id='hidden' type='hidden'><input id='dis' disabled>
          <div id='ti' tabindex='-1'></div><div id='plain'></div><p id='p'>x</p>
        </body>
        """)

      %{doc: doc}
    end

    for {sel, focusable} <- [
          {"#a-href", true},
          {"#a-bare", false},
          {"#btn", true},
          {"#sel", true},
          {"#ta", true},
          {"#in", true},
          {"#hidden", false},
          {"#dis", false},
          {"#ti", true},
          {"#plain", false},
          {"#p", false}
        ] do
      test "#{sel} focusable? == #{focusable}", %{doc: doc} do
        el = DOM.query_selector(doc, unquote(sel))
        Node.focus(el)
        active = DOM.active_element(doc)
        got = active && active.node_id == el.node_id
        assert got == unquote(focusable)
      end
    end
  end

  describe "non-focusable / detached focus is a no-op" do
    test "focusing a non-focusable element leaves the active element unchanged" do
      doc = new_document("<body><input id='i'></body>")
      i = DOM.query_selector(doc, "#i")
      p = DOM.query_selector(doc, "body")
      Node.focus(i)

      # focusing a <body> (not focusable) is a no-op — active stays the input
      Node.focus(p)
      assert DOM.active_element(doc).node_id == i.node_id
    end

    test "focusing a detached element is a no-op" do
      doc = new_document("<body></body>")
      detached = DOM.create_element(doc, "input")
      Node.focus(detached)
      assert DOM.Element.get_attribute(DOM.active_element(doc), "id") == nil
      assert Node.node_name(DOM.active_element(doc)) == "body"
    end
  end

  describe ":focus / :focus-within / :focus-visible" do
    test ":focus matches only the active element" do
      doc = new_document("<body><input id='i'><input id='j'></body>")
      i = DOM.query_selector(doc, "#i")
      Node.focus(i)

      assert DOM.Element.matches(i, ":focus")
      refute DOM.Element.matches(DOM.query_selector(doc, "#j"), ":focus")
    end

    test ":focus-visible matches the active element (aliases :focus here)" do
      doc = new_document("<body><input id='i'></body>")
      i = DOM.query_selector(doc, "#i")
      Node.focus(i)
      assert DOM.Element.matches(i, ":focus-visible")
    end

    test ":focus-within matches the active element and its ancestors" do
      doc =
        new_document("<body><div id='outer'><div id='mid'><input id='inner'></div></div></body>")

      inner = DOM.query_selector(doc, "#inner")
      Node.focus(inner)

      assert DOM.Element.matches(inner, ":focus-within")
      assert DOM.Element.matches(DOM.query_selector(doc, "#mid"), ":focus-within")
      assert DOM.Element.matches(DOM.query_selector(doc, "#outer"), ":focus-within")
      # the focused element matches both :focus and :focus-within
      assert DOM.Element.matches(inner, ":focus")
    end

    test ":focus-within does not match a sibling subtree" do
      doc = new_document("<body><div id='a'><input id='i'></div><div id='b'></div></body>")
      Node.focus(DOM.query_selector(doc, "#i"))
      refute DOM.Element.matches(DOM.query_selector(doc, "#b"), ":focus-within")
    end
  end
end
