defmodule DOM.Shadow.SlottedSelectorTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.ShadowRoot

  # ::slotted(sel) is a pseudo-element: it styles a slot's assigned (light-DOM)
  # elements from within a shadow-tree stylesheet, but it is NEVER returned or
  # matched by the DOM query APIs — querySelectorAll and matches/2 both yield
  # nothing for it, exactly like ::before/::after. (Confirmed against the browser
  # oracle in test/integration/shadow_test.exs.) These tests pin that behavior and
  # guard the related invariant that a shadow-scoped query only ever returns the
  # shadow root's own descendants, never the light-DOM nodes slotted into it.

  defp slotted_host do
    doc = new_document("<div id='host'><a class='x'>1</a><b>2</b></div>")
    host = DOM.query_selector(doc, "#host")
    s = Element.attach_shadow(host, :open)
    ShadowRoot.set_inner_html(s, "<slot></slot>")
    {doc, host, s}
  end

  defp names(nodes), do: Enum.map(nodes, &String.downcase(DOM.Node.node_name(&1)))

  describe "::slotted(sel)" do
    test "matches nothing in a shadow-scoped querySelectorAll" do
      {_doc, _host, s} = slotted_host()

      assert DOM.ShadowRoot.query_selector_all(s, "::slotted(a)") == []
      assert DOM.ShadowRoot.query_selector_all(s, "::slotted(*)") == []
      assert DOM.ShadowRoot.query_selector_all(s, "::slotted(.x)") == []
    end

    test "matches nothing via matches/2 on an assigned element" do
      {doc, _host, _s} = slotted_host()
      a = DOM.query_selector(doc, "a")

      refute DOM.Element.matches(a, "::slotted(a)")
      refute DOM.Element.matches(a, "::slotted(*)")
    end
  end

  describe "shadow-scoped query excludes slotted light-DOM nodes" do
    test "a universal selector returns only the shadow root's descendants" do
      {_doc, _host, s} = slotted_host()

      # only the <slot> lives in the shadow tree; the assigned <a>/<b> are light DOM
      assert names(DOM.ShadowRoot.query_selector_all(s, "*")) == ["slot"]
    end

    test "a type selector does not reach a slotted light-DOM element" do
      {_doc, _host, s} = slotted_host()

      assert DOM.ShadowRoot.query_selector_all(s, "a") == []
      assert DOM.ShadowRoot.query_selector_all(s, "b") == []
    end
  end
end
