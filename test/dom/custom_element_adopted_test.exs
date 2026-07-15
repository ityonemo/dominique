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
    # defined + upgraded in the SOURCE (so the element carries its definition), but
    # never inserted — a detached upgraded element.
    DOM.define_element(src, "x-foo", reporting_def(parent))

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

  test "the definition travels with the element: adopted fires even when dst has no registration" do
    parent = self()
    src = new_document("<div id='s'></div>")
    dst = new_document("<div id='d'></div>")
    # only the SOURCE registers x-foo; the element is upgraded there and carries its
    # definition, so adoption into dst (no registration) still fires adopted (browser
    # semantics — an element retains its definition across adoption).
    DOM.define_element(src, "x-foo", reporting_def(parent))

    foo = DOM.create_element(src, "x-foo")
    foo_id = foo.node_id
    flush()

    adopted = DOM.adopt_node(dst, foo)

    assert_received {:adopted, ^foo_id, _old, _new}
    # and it is still :defined in dst (carries a definition, though dst's registry lacks it)
    assert DOM.Element.matches(adopted, ":defined")
    # re-inserting into dst fires connectedCallback (still upgraded)
    d = DOM.query_selector(dst, "#d")
    Node.append_child(d, adopted)
    assert_received {:connected, ^foo_id}
  end

  test "a later define in dst does NOT re-upgrade an already-upgraded adopted element" do
    parent = self()
    src = new_document("<div id='s'></div>")
    dst = new_document("<div id='d'></div>")
    DOM.define_element(src, "x-foo", reporting_def(parent))
    foo = DOM.create_element(src, "x-foo")
    DOM.adopt_node(dst, foo)
    flush()

    # dst defines x-foo with a DIFFERENT (marker) definition; the already-upgraded
    # adopted element must not be re-constructed.
    DOM.define_element(dst, "x-foo", %Def{
      constructed: fn el -> send(parent, {:reupgraded, el.node_id}) end
    })

    refute_received {:reupgraded, _}
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
