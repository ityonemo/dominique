defmodule DOM.IndeterminateTest do
  use DOM.Case, async: true

  # :indeterminate has three sources (browser-verified):
  #  - a checkbox whose .indeterminate PROPERTY is set (DOM.set_indeterminate/2);
  #    a click clears it.
  #  - a radio whose entire name group has no checked member.
  #  - a <progress> with no value attribute.

  alias DOM.Event
  alias DOM.Node

  defp click(el), do: Node.dispatch_event(el, Event.new("click", bubbles: true, cancelable: true))

  describe "checkbox .indeterminate property" do
    test "defaults to not indeterminate; set_indeterminate turns it on (not an attribute)" do
      doc = new_document("<body><input type='checkbox' id='c'></body>")
      c = DOM.query_selector(doc, "#c")

      refute DOM.matches(c, ":indeterminate")
      DOM.set_indeterminate(c, true)
      assert DOM.matches(c, ":indeterminate")
      refute DOM.Element.has_attribute(c, "indeterminate")
    end

    test "a click clears indeterminate" do
      doc = new_document("<body><input type='checkbox' id='c'></body>")
      c = DOM.query_selector(doc, "#c")
      DOM.set_indeterminate(c, true)

      click(c)
      refute DOM.matches(c, ":indeterminate")
    end
  end

  describe "radio group with none checked" do
    test "a radio whose group has no checked member is :indeterminate" do
      doc =
        new_document(
          "<body><input type='radio' name='g' id='r1'><input type='radio' name='g' id='r2'></body>"
        )

      assert DOM.matches(DOM.query_selector(doc, "#r1"), ":indeterminate")
      assert DOM.matches(DOM.query_selector(doc, "#r2"), ":indeterminate")
    end

    test "checking a group member clears :indeterminate for the whole group" do
      doc =
        new_document(
          "<body><input type='radio' name='g' id='r1'><input type='radio' name='g' id='r2'></body>"
        )

      r1 = DOM.query_selector(doc, "#r1")
      click(r1)

      refute DOM.matches(r1, ":indeterminate")
      refute DOM.matches(DOM.query_selector(doc, "#r2"), ":indeterminate")
    end
  end

  describe "progress without value" do
    test "a <progress> with no value is :indeterminate; with value is not" do
      doc =
        new_document(
          "<body><progress id='p'></progress><progress id='p2' value='0.5'></progress></body>"
        )

      assert DOM.matches(DOM.query_selector(doc, "#p"), ":indeterminate")
      refute DOM.matches(DOM.query_selector(doc, "#p2"), ":indeterminate")
    end
  end
end
