defmodule DOM.Event.AddRemoveListenerTest do
  use DOM.Case, async: true

  # E1: the add/removeEventListener public API on DOM.Node. Dispatch is E2, so at
  # this phase we verify registration/removal are stored and are re-entrant-safe
  # (callable from inside the server, an event listener during dispatch). Observable
  # count is read via the test-only DOM.Node.__listeners/1 introspection helper.

  alias DOM.Node

  test "add_event_listener registers; remove_event_listener removes" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    fun = fn _event -> :ok end

    Node.add_event_listener(d, "click", fun)
    assert length(Node.__listeners(d)) == 1

    Node.remove_event_listener(d, "click", fun)
    assert Node.__listeners(d) == []
  end

  test "capture flag distinguishes listeners with the same fn" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    fun = fn _ -> :ok end

    Node.add_event_listener(d, "click", fun, capture: false)
    Node.add_event_listener(d, "click", fun, capture: true)
    assert length(Node.__listeners(d)) == 2

    # removing the bubble-phase one leaves the capture-phase one
    Node.remove_event_listener(d, "click", fun, capture: false)
    assert [%DOM.Listener{capture: true}] = Node.__listeners(d)
  end

  test "add/remove are callable re-entrantly (from inside the server)" do
    doc = new_document("<div id='d'></div>")
    d = DOM.query_selector(doc, "#d")
    fun = fn _ -> :ok end

    DOM.lambda(d.server, fn -> Node.add_event_listener(d, "click", fun) end)
    assert length(Node.__listeners(d)) == 1

    DOM.lambda(d.server, fn -> Node.remove_event_listener(d, "click", fun) end)
    assert Node.__listeners(d) == []
  end

  test "removeChild detaches but KEEPS listeners (the node is still alive)" do
    # Per the DOM, removeChild does not drop listeners — a detached node retains
    # them and can be re-inserted. Only actual destruction (e.g. replacing a
    # parent's children via innerHTML, or cross-document adoption) drops them.
    doc = new_document("<div id='p'><span id='c'></span></div>")
    p = DOM.query_selector(doc, "#p")
    c = DOM.query_selector(doc, "#c")
    Node.add_event_listener(c, "click", fn _ -> :ok end)

    Node.remove_child(p, c)
    assert length(Node.__listeners(c)) == 1
  end

  test "listeners are dropped when the node is actually destroyed (set_text_content)" do
    doc = new_document("<div id='p'><span id='c'></span></div>")
    p = DOM.query_selector(doc, "#p")
    c = DOM.query_selector(doc, "#c")
    Node.add_event_listener(c, "click", fn _ -> :ok end)

    # set_text_content deletes p's child subtrees (destroying <span id=c>)
    Node.set_text_content(p, "gone")
    assert Node.__listeners(c) == []
  end
end
