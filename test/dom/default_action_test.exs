defmodule DOM.DefaultActionTest do
  use DOM.Case, async: true

  # Default actions: dispatching a `click` on a checkbox/radio runs the activation
  # behavior (toggle checkedness) UNLESS a listener called preventDefault. Checkedness
  # is a PROPERTY separate from the `checked` attribute (the attribute is the default;
  # click toggles the property, leaving the attribute alone). :checked tracks the
  # property. Browser-verified in the default-action-semantics memory.

  alias DOM.Element
  alias DOM.Event
  alias DOM.Node

  defp click(el), do: Node.dispatch_event(el, Event.new("click", bubbles: true, cancelable: true))

  describe "checkbox click toggles checkedness" do
    test "an unchecked checkbox becomes :checked after a click" do
      doc = new_document("<body><input type='checkbox' id='c'></body>")
      c = DOM.query_selector(doc, "#c")

      refute DOM.Element.matches(c, ":checked")
      click(c)
      assert DOM.Element.matches(c, ":checked")
    end

    test "a checkbox with the checked attribute toggles OFF on click" do
      doc = new_document("<body><input type='checkbox' id='c' checked></body>")
      c = DOM.query_selector(doc, "#c")

      assert DOM.Element.matches(c, ":checked")
      click(c)
      refute DOM.Element.matches(c, ":checked")
    end

    test "the checked ATTRIBUTE is unchanged by a click (property != attribute)" do
      doc = new_document("<body><input type='checkbox' id='c'></body>")
      c = DOM.query_selector(doc, "#c")

      click(c)
      assert DOM.Element.matches(c, ":checked")
      # the attribute did not appear — only the checkedness property changed
      refute Element.has_attribute(c, "checked")
    end

    test "preventDefault stops the toggle" do
      doc = new_document("<body><input type='checkbox' id='c'></body>")
      c = DOM.query_selector(doc, "#c")
      Node.add_event_listener(c, "click", fn %Event{} = e -> Event.prevent_default(e) end)

      click(c)
      refute DOM.Element.matches(c, ":checked")
    end

    test "a non-cancelable click still toggles" do
      doc = new_document("<body><input type='checkbox' id='c'></body>")
      c = DOM.query_selector(doc, "#c")

      Node.dispatch_event(c, Event.new("click", cancelable: false))
      assert DOM.Element.matches(c, ":checked")
    end

    test "dispatchEvent returns false when default is prevented" do
      doc = new_document("<body><input type='checkbox' id='c'></body>")
      c = DOM.query_selector(doc, "#c")
      Node.add_event_listener(c, "click", fn %Event{} = e -> Event.prevent_default(e) end)

      refute Node.dispatch_event(c, Event.new("click", cancelable: true))
    end
  end

  describe "radio click" do
    test "clicking a radio checks it and unchecks others in the same name group" do
      doc =
        new_document(
          "<body><input type='radio' name='g' id='r1'><input type='radio' name='g' id='r2'>" <>
            "<input type='radio' name='other' id='o'></body>"
        )

      r1 = DOM.query_selector(doc, "#r1")
      r2 = DOM.query_selector(doc, "#r2")
      o = DOM.query_selector(doc, "#o")

      click(r1)
      assert DOM.Element.matches(r1, ":checked")

      click(r2)
      assert DOM.Element.matches(r2, ":checked")
      refute DOM.Element.matches(r1, ":checked")
      # a different group is unaffected
      refute DOM.Element.matches(o, ":checked")
    end

    test "a radio does not toggle off when clicked again" do
      doc = new_document("<body><input type='radio' name='g' id='r'></body>")
      r = DOM.query_selector(doc, "#r")

      click(r)
      click(r)
      # radios stay checked once activated (no toggle-off)
      assert DOM.Element.matches(r, ":checked")
    end
  end

  test "clicking a non-checkbox does nothing checkable" do
    doc = new_document("<body><button id='btn'>x</button></body>")
    btn = DOM.query_selector(doc, "#btn")
    # no crash, no checkedness
    click(btn)
    refute DOM.Element.matches(btn, ":checked")
  end
end
