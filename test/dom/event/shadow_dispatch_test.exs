defmodule DOM.Event.ShadowDispatchTest do
  use DOM.Case, async: true

  # E4: shadow-coupled dispatch. composed events cross the shadow boundary to the
  # host and beyond; non-composed stop at the shadow root. event.target is
  # retargeted per node: shadow-internal listeners see the real target, light-DOM
  # listeners see the host. composed_path/1 returns the full path.

  alias DOM.Element
  alias DOM.Event
  alias DOM.Node

  # <section id=sec><div id=host>#shadow: <span id=inner></span></div></section>
  defp shadow_tree do
    doc = new_document("<section id='sec'><div id='host'></div></section>")
    sec = DOM.query_selector(doc, "#sec")
    host = DOM.query_selector(doc, "#host")
    s = Element.attach_shadow(host, :open)
    DOM.ShadowRoot.set_inner_html(s, "<span id='inner'>x</span>")
    inner = DOM.query_selector(s, "#inner")
    %{doc: doc, sec: sec, host: host, shadow: s, inner: inner}
  end

  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "composed: true" do
    test "bubbles across the shadow boundary to the light DOM" do
      %{sec: sec, host: host, shadow: s, inner: inner} = shadow_tree()
      me = self()

      for {label, node} <- [inner: inner, shadow: s, host: host, sec: sec] do
        Node.add_event_listener(node, "evt", fn _ -> send(me, label) end)
      end

      Node.dispatch_event(inner, Event.new("evt", bubbles: true, composed: true))
      assert drain() == [:inner, :shadow, :host, :sec]
    end

    test "retargets event.target to the host for light-DOM listeners" do
      %{sec: sec, host: host, shadow: s, inner: inner} = shadow_tree()
      me = self()

      for {label, node} <- [inner: inner, shadow: s, host: host, sec: sec] do
        Node.add_event_listener(node, "evt", fn ev -> send(me, {label, ev.target.node_id}) end)
      end

      Node.dispatch_event(inner, Event.new("evt", bubbles: true, composed: true))

      results = Map.new(drain())
      # shadow-internal listeners see the real target
      assert results[:inner] == inner.node_id
      assert results[:shadow] == inner.node_id
      # light-DOM listeners see the host
      assert results[:host] == host.node_id
      assert results[:sec] == host.node_id
    end
  end

  describe "composed: false" do
    test "stops at the shadow root, never reaching the host" do
      %{sec: sec, host: host, shadow: s, inner: inner} = shadow_tree()
      me = self()

      for {label, node} <- [inner: inner, shadow: s, host: host, sec: sec] do
        Node.add_event_listener(node, "evt", fn _ -> send(me, label) end)
      end

      Node.dispatch_event(inner, Event.new("evt", bubbles: true, composed: false))
      assert drain() == [:inner, :shadow]
    end
  end

  describe "composed_path/1" do
    test "composed path includes the shadow root and light ancestors" do
      %{doc: doc, sec: sec, host: host, shadow: s, inner: inner} = shadow_tree()

      path = Node.composed_path(inner, Event.new("evt", composed: true))
      ids = Enum.map(path, & &1.node_id)

      # inner, shadowRoot, host, then the light ancestors up to the document.
      # The path starts at inner/shadowRoot/host and ends at the document.
      assert Enum.take(ids, 3) == [inner.node_id, s.node_id, host.node_id]
      assert List.last(ids) == doc.node_id
      # sec is a light-DOM ancestor of the host, so it is on the path after the host
      assert sec.node_id in ids
      # and it appears after the host (outward order)
      assert Enum.find_index(ids, &(&1 == sec.node_id)) >
               Enum.find_index(ids, &(&1 == host.node_id))
    end

    test "non-composed path stops at the shadow root" do
      %{shadow: s, inner: inner} = shadow_tree()

      path = Node.composed_path(inner, Event.new("evt", composed: false))
      assert Enum.map(path, & &1.node_id) == [inner.node_id, s.node_id]
    end
  end
end
