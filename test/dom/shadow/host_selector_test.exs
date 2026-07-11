defmodule DOM.Shadow.HostSelectorTest do
  use DOM.Case, async: true

  alias DOM.Element
  alias DOM.ShadowRoot

  defp shadow(light_host, shadow_html) do
    doc = new_document(light_host)
    host = DOM.query_selector(doc, "#host")
    s = Element.attach_shadow(host, :open)
    ShadowRoot.set_inner_html(s, shadow_html)
    {doc, host, s}
  end

  defp ids(nodes), do: Enum.map(nodes, &Element.get_attribute(&1, "id"))

  describe ":host" do
    # querySelectorAll(":host") returns nothing — the host is not a descendant of
    # the shadow root, so it is outside the searched set. `:host` is only meaningful
    # in a stylesheet scoped to the shadow tree; the interrogable surface is matches/2.
    test "does not appear in a shadow-scoped querySelectorAll (host is not searched)" do
      {_doc, _host, s} = shadow("<div id='host' class='k'></div>", "<p id='p'>x</p>")

      assert DOM.query_selector_all(s, ":host") == []
    end

    test "matches nothing in a document-scoped (light) query" do
      {doc, _host, _s} = shadow("<div id='host'></div>", "<p>x</p>")
      assert DOM.query_selector_all(doc, ":host") == []
    end

    test "matches on the host itself via matches/2" do
      {_doc, host, _s} = shadow("<div id='host'></div>", "<p>x</p>")
      assert DOM.matches(host, ":host")
    end
  end

  describe ":host(sel)" do
    # As with :host, querySelectorAll never returns the host; matches/2 is the surface.
    test "matches the host via matches/2 only when the host matches sel" do
      {_doc, host, _s} = shadow("<div id='host' class='themed'></div>", "<p>x</p>")

      assert DOM.matches(host, ":host(.themed)")
      refute DOM.matches(host, ":host(.other)")
    end
  end

  describe ":host-context(sel)" do
    # :host-context is Chromium-only in browsers (Firefox throws), so it is not in
    # the oracle test; verified here via matches/2 on the host.
    test "matches the host when an ancestor matches sel" do
      {_doc, host, _s} =
        shadow("<section class='dark'><div id='host'></div></section>", "<p>x</p>")

      # the host's ancestor <section class=dark> satisfies the context
      assert DOM.matches(host, ":host-context(.dark)")
    end

    test "does not match when no ancestor matches sel" do
      {_doc, host, _s} =
        shadow("<section class='light'><div id='host'></div></section>", "<p>x</p>")

      refute DOM.matches(host, ":host-context(.dark)")
    end
  end

  describe ":host combined with descendants" do
    test ":host p matches a shadow descendant of the host" do
      {_doc, _host, s} = shadow("<div id='host'></div>", "<p id='p'>x</p>")
      # :host <descendant> — the shadow <p> is a descendant of the host
      assert ids(DOM.query_selector_all(s, ":host p")) == ["p"]
    end
  end
end
