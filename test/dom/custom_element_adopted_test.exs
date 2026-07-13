defmodule DOM.CustomElementAdoptedTest do
  use DOM.Case, async: true

  # adoptedCallback fires when an element's node document changes (cross-document
  # adoptNode). Browser-verified: adopting a CONNECTED element fires disconnected
  # (source) then adopted; a detached element fires only adopted; a same-document
  # adopt fires nothing. In Dominique each document server has its own registry, so
  # the DESTINATION's definition governs adoptedCallback (documented limitation).

  alias DOM.CustomElementDefinition, as: Def
  alias DOM.Node

  defp reporting_def(parent) do
    %Def{
      connected: fn el -> send(parent, {:connected, el.node_id}) end,
      disconnected: fn el -> send(parent, {:disconnected, el.node_id}) end,
      adopted: fn el, old_doc, new_doc ->
        send(parent, {:adopted, el.node_id, old_doc.node_id, new_doc.node_id})
      end
    }
  end

  test "adopting a connected element fires disconnected (src) then adopted (dst)" do
    parent = self()
    src = new_document("<div id='s'><x-foo></x-foo></div>")
    dst = new_document("<div id='d'></div>")

    DOM.define_element(src, "x-foo", reporting_def(parent))
    DOM.define_element(dst, "x-foo", reporting_def(parent))
    # drain the src upgrade's connected/etc. from the mailbox
    flush()

    foo = DOM.query_selector(src, "x-foo")
    foo_id = foo.node_id

    adopted = DOM.adopt_node(dst, foo)

    # disconnected fired in the source (it was connected there)
    assert_received {:disconnected, ^foo_id}
    # adopted fired in the destination with (old_doc, new_doc)
    assert_received {:adopted, ^foo_id, old_doc, new_doc}
    assert old_doc == src.node_id
    assert new_doc == dst.node_id
    # the handle is now owned by dst
    assert Node.owner_document(adopted).node_id == dst.node_id
  end

  test "adopting a detached element fires only adopted (no disconnected)" do
    parent = self()
    src = new_document("<div id='s'></div>")
    dst = new_document("<div id='d'></div>")
    DOM.define_element(dst, "x-foo", reporting_def(parent))

    foo = DOM.create_element(src, "x-foo")
    flush()

    DOM.adopt_node(dst, foo)

    assert_received {:adopted, _id, _old, _new}
    refute_received {:disconnected, _}
  end

  test "a same-document adopt fires nothing (document unchanged)" do
    parent = self()
    doc = new_document("<div id='a'></div><div id='b'></div>")
    DOM.define_element(doc, "x-foo", reporting_def(parent))
    a = DOM.query_selector(doc, "#a")
    foo = DOM.create_element(doc, "x-foo")
    Node.append_child(a, foo)
    flush()

    # adopt within the SAME document — no document change, so no adopted/disconnected
    DOM.adopt_node(doc, foo)

    refute_received {:adopted, _, _, _}
  end

  test "no adoptedCallback when the destination has no definition" do
    parent = self()
    src = new_document("<div id='s'></div>")
    dst = new_document("<div id='d'></div>")
    DOM.define_element(src, "x-foo", reporting_def(parent))

    foo = DOM.create_element(src, "x-foo")
    flush()

    DOM.adopt_node(dst, foo)
    refute_received {:adopted, _, _, _}
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
