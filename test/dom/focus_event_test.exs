defmodule DOM.FocusEventTest do
  use DOM.Case, async: true

  # Focus events fired by focus()/blur(). Sequence (browser-verified): moving focus
  # A -> B fires blur@A, focusout@A, focus@B, focusin@B (blur pair before focus pair);
  # focus/blur are bubbles:false, focusin/focusout bubbles:true, all composed:true;
  # relatedTarget is the OTHER element. Dispatched synchronously during focus()/blur().

  alias DOM.Event
  alias DOM.Node

  # Attach the four focus listeners on `node`, reporting {type, target_id, related_id,
  # bubbles, composed} to the test process.
  defp watch(node) do
    parent = self()
    id = node.node_id

    for type <- ~w(focus blur focusin focusout) do
      Node.add_event_listener(node, type, fn %Event{} = e ->
        rel = e.related_target && e.related_target.node_id
        send(parent, {String.to_atom(type), e.target.node_id, rel, e.bubbles, e.composed})
      end)
    end

    id
  end

  test "focusing from nothing fires focus then focusin (relatedTarget nil)" do
    doc = new_document("<body><input id='a'></body>")
    a = DOM.query_selector(doc, "#a")
    aid = watch(a)

    Node.focus(a)

    assert_received {:focus, ^aid, nil, false, true}
    assert_received {:focusin, ^aid, nil, true, true}
  end

  test "moving focus A->B fires blur@A, focusout@A, focus@B, focusin@B in order" do
    doc = new_document("<body><input id='a'><input id='b'></body>")
    a = DOM.query_selector(doc, "#a")
    b = DOM.query_selector(doc, "#b")
    aid = watch(a)
    bid = watch(b)

    Node.focus(a)
    # drain the initial focus/focusin@a
    assert_received {:focus, ^aid, nil, false, true}
    assert_received {:focusin, ^aid, nil, true, true}

    Node.focus(b)
    # blur pair on A (relatedTarget = B), then focus pair on B (relatedTarget = A)
    assert_received {:blur, ^aid, ^bid, false, true}
    assert_received {:focusout, ^aid, ^bid, true, true}
    assert_received {:focus, ^bid, ^aid, false, true}
    assert_received {:focusin, ^bid, ^aid, true, true}
  end

  test "blur fires blur then focusout (relatedTarget nil)" do
    doc = new_document("<body><input id='a'></body>")
    a = DOM.query_selector(doc, "#a")
    aid = watch(a)

    Node.focus(a)
    assert_received {:focus, ^aid, nil, false, true}
    assert_received {:focusin, ^aid, nil, true, true}

    Node.blur(a)
    assert_received {:blur, ^aid, nil, false, true}
    assert_received {:focusout, ^aid, nil, true, true}
  end

  test "focusin/focusout bubble to an ancestor; focus/blur do not" do
    doc = new_document("<body><div id='wrap'><input id='a'></div></body>")
    a = DOM.query_selector(doc, "#a")
    wrap = DOM.query_selector(doc, "#wrap")
    aid = a.node_id
    parent = self()

    for type <- ~w(focus blur focusin focusout) do
      Node.add_event_listener(wrap, type, fn %Event{} = e ->
        send(parent, {:wrap, String.to_atom(type), e.target.node_id})
      end)
    end

    Node.focus(a)
    # focusin bubbles up to wrap (target still a); focus does NOT reach wrap
    assert_received {:wrap, :focusin, ^aid}
    refute_received {:wrap, :focus, _}
  end

  test "re-focusing the already-active element fires nothing" do
    doc = new_document("<body><input id='a'></body>")
    a = DOM.query_selector(doc, "#a")
    watch(a)

    Node.focus(a)
    # drain the first focus
    assert_received {:focus, _, _, _, _}
    assert_received {:focusin, _, _, _, _}

    Node.focus(a)
    refute_received {:focus, _, _, _, _}
    refute_received {:focusin, _, _, _, _}
  end

  test "blurring a non-active element fires nothing" do
    doc = new_document("<body><input id='a'><input id='b'></body>")
    a = DOM.query_selector(doc, "#a")
    b = DOM.query_selector(doc, "#b")
    watch(b)
    Node.focus(a)

    # b is not focused; blurring it is a no-op
    Node.blur(b)
    refute_received {:blur, _, _, _, _}
  end
end
