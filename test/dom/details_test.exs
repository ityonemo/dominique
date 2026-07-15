defmodule DOM.DetailsTest do
  use DOM.Case, async: true

  # <details> activation: clicking its <summary> toggles the details `open` ATTRIBUTE
  # (unlike checkbox, this is a real attribute change), unless preventDefault. The
  # :open pseudo matches details[open] / dialog[open]. Browser-verified.

  alias DOM.Element
  alias DOM.Event
  alias DOM.Node

  defp click(el), do: Node.dispatch_event(el, Event.new("click", bubbles: true, cancelable: true))

  describe "summary click toggles open" do
    setup do
      doc = new_document("<body><details id='d'><summary id='s'>t</summary>body</details></body>")
      %{doc: doc, d: DOM.query_selector(doc, "#d"), s: DOM.query_selector(doc, "#s")}
    end

    test "clicking the summary opens a closed details", %{d: d, s: s} do
      refute Element.has_attribute(d, "open")
      click(s)
      assert Element.has_attribute(d, "open")
    end

    test "clicking the summary again closes it", %{d: d, s: s} do
      click(s)
      click(s)
      refute Element.has_attribute(d, "open")
    end

    test "preventDefault stops the toggle", %{d: d, s: s} do
      Node.add_event_listener(s, "click", fn %Event{} = e -> Event.prevent_default(e) end)
      click(s)
      refute Element.has_attribute(d, "open")
    end

    test "clicking the details body (not summary) does not toggle" do
      doc =
        new_document(
          "<body><details id='d' open><summary>t</summary><p id='p'>b</p></details></body>"
        )

      d = DOM.query_selector(doc, "#d")
      click(DOM.query_selector(doc, "#p"))
      assert Element.has_attribute(d, "open")
    end
  end

  describe ":open pseudo" do
    test "matches details[open] and dialog[open], not closed ones" do
      doc =
        new_document(
          "<body><details id='d1' open><summary>a</summary></details>" <>
            "<details id='d2'><summary>b</summary></details>" <>
            "<dialog id='dlg' open>x</dialog><div id='plain'></div></body>"
        )

      assert DOM.Element.matches(DOM.query_selector(doc, "#d1"), ":open")
      refute DOM.Element.matches(DOM.query_selector(doc, "#d2"), ":open")
      assert DOM.Element.matches(DOM.query_selector(doc, "#dlg"), ":open")
      refute DOM.Element.matches(DOM.query_selector(doc, "#plain"), ":open")
    end

    test "toggling via summary click updates :open" do
      doc = new_document("<body><details id='d'><summary id='s'>t</summary></details></body>")
      d = DOM.query_selector(doc, "#d")
      refute DOM.Element.matches(d, ":open")
      click(DOM.query_selector(doc, "#s"))
      assert DOM.Element.matches(d, ":open")
    end
  end
end
