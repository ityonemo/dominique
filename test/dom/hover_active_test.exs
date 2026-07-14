defmodule DOM.HoverActiveTest do
  use DOM.Case, async: true

  # :hover / :active — pointer state. No DOM API sets them in a browser (real pointer
  # input), so Dominique provides DOM.set_hover/1 and DOM.set_active/1 as conveniences.
  # Both match the set element AND all its ancestors (the "hover chain"), not siblings.
  # No oracle test: headless browsers don't reflect :hover via synthetic input, and the
  # ancestor-chain rule is spec-unambiguous. See target-hover-active-semantics memory.

  defp q(doc, sel), do: DOM.query_selector(doc, sel)

  describe ":hover" do
    setup do
      doc =
        new_document(
          "<body><div id='outer'><div id='mid'><button id='btn'>x</button></div><div id='sib'></div></div></body>"
        )

      %{doc: doc}
    end

    test "nothing hovered: nothing matches :hover", %{doc: doc} do
      refute DOM.Element.matches(q(doc, "#btn"), ":hover")
    end

    test "set_hover matches the element and all its ancestors", %{doc: doc} do
      DOM.set_hover(q(doc, "#btn"))

      assert DOM.Element.matches(q(doc, "#btn"), ":hover")
      assert DOM.Element.matches(q(doc, "#mid"), ":hover")
      assert DOM.Element.matches(q(doc, "#outer"), ":hover")
      assert DOM.Element.matches(q(doc, "body"), ":hover")
      # not a sibling subtree
      refute DOM.Element.matches(q(doc, "#sib"), ":hover")
    end

    test "clear_hover clears :hover", %{doc: doc} do
      DOM.set_hover(q(doc, "#btn"))
      DOM.clear_hover(doc)
      refute DOM.Element.matches(q(doc, "#btn"), ":hover")
    end

    test "moving hover updates the chain", %{doc: doc} do
      DOM.set_hover(q(doc, "#btn"))
      DOM.set_hover(q(doc, "#sib"))

      refute DOM.Element.matches(q(doc, "#btn"), ":hover")
      refute DOM.Element.matches(q(doc, "#mid"), ":hover")
      assert DOM.Element.matches(q(doc, "#sib"), ":hover")
      assert DOM.Element.matches(q(doc, "#outer"), ":hover")
    end
  end

  describe ":active" do
    setup do
      doc = new_document("<body><div id='outer'><button id='btn'>x</button></div></body>")
      %{doc: doc}
    end

    test "set_active matches the element and its ancestors", %{doc: doc} do
      DOM.set_active(q(doc, "#btn"))

      assert DOM.Element.matches(q(doc, "#btn"), ":active")
      assert DOM.Element.matches(q(doc, "#outer"), ":active")
    end

    test "clear_active clears :active", %{doc: doc} do
      DOM.set_active(q(doc, "#btn"))
      DOM.clear_active(doc)
      refute DOM.Element.matches(q(doc, "#btn"), ":active")
    end
  end

  test ":hover and :active are independent" do
    doc = new_document("<body><button id='b'>x</button></body>")
    b = DOM.query_selector(doc, "#b")
    DOM.set_hover(b)

    assert DOM.Element.matches(b, ":hover")
    refute DOM.Element.matches(b, ":active")
  end
end
