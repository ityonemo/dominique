defmodule DOM.CustomElementTest do
  use DOM.Case, async: true

  # Custom element reactions. Reactions run SYNCHRONOUSLY with their trigger (verified
  # against both browsers — connectedCallback fires DURING appendChild, not deferred),
  # so a callback's message arrives before the op returns and we can assert_received
  # with no wait. Semantics recorded in the custom-element-semantics memory.

  alias DOM.CustomElementDefinition, as: Def
  alias DOM.Element
  alias DOM.Node

  # A definition whose callbacks report to the test process.
  defp reporting_def(parent, opts \\ []) do
    %Def{
      observed_attributes: Keyword.get(opts, :observed, []),
      constructed: fn el -> send(parent, {:constructed, el.node_id}) end,
      connected: fn el -> send(parent, {:connected, el.node_id}) end,
      disconnected: fn el -> send(parent, {:disconnected, el.node_id}) end,
      attribute_changed: fn _el, name, old, new -> send(parent, {:attr, name, old, new}) end
    }
  end

  describe "define / get" do
    test "define registers a definition; get returns it" do
      doc = new_document("<div></div>")
      def = %Def{}
      refute DOM.custom_element_get(doc, "x-foo")
      DOM.define_element(doc, "x-foo", def)
      assert DOM.custom_element_get(doc, "x-foo") == def
    end

    test "defining the same name twice raises NotSupportedError" do
      doc = new_document("<div></div>")
      DOM.define_element(doc, "x-foo", %Def{})

      assert_raise DOM.NotSupportedError, fn ->
        DOM.define_element(doc, "x-foo", %Def{})
      end
    end

    test "a name without a hyphen is invalid" do
      doc = new_document("<div></div>")

      assert_raise ArgumentError, fn ->
        DOM.define_element(doc, "notcustom", %Def{})
      end
    end
  end

  describe "lifecycle (synchronous)" do
    test "constructed fires at create_element for a defined name" do
      doc = new_document("<div id='p'></div>")
      DOM.define_element(doc, "x-foo", reporting_def(self()))

      el = DOM.create_element(doc, "x-foo")
      assert_received {:constructed, id}
      assert id == el.node_id
    end

    test "connected fires synchronously during append; disconnected during remove" do
      doc = new_document("<div id='p'></div>")
      p = DOM.query_selector(doc, "#p")
      DOM.define_element(doc, "x-foo", reporting_def(self()))
      el = DOM.create_element(doc, "x-foo")

      Node.append_child(p, el)
      assert_received {:connected, id}
      assert id == el.node_id

      Node.remove_child(p, el)
      assert_received {:disconnected, ^id}
    end

    test "attribute_changed fires for observed attributes on every set (even same value)" do
      doc = new_document("<div></div>")
      DOM.define_element(doc, "x-foo", reporting_def(self(), observed: ["k"]))
      el = DOM.create_element(doc, "x-foo")

      Element.set_attribute(el, "k", "1")
      assert_received {:attr, "k", nil, "1"}

      Element.set_attribute(el, "k", "1")
      # fires again even though the value did not change
      assert_received {:attr, "k", "1", "1"}
    end

    test "attribute_changed does NOT fire for un-observed attributes" do
      doc = new_document("<div></div>")
      DOM.define_element(doc, "x-foo", reporting_def(self(), observed: ["k"]))
      el = DOM.create_element(doc, "x-foo")

      Element.set_attribute(el, "other", "1")
      refute_received {:attr, "other", _, _}
    end
  end

  describe "upgrade on define" do
    test "define upgrades an already-inserted element: constructed, attr replay, connected" do
      doc = new_document("<div id='p'><x-bar y='2'></x-bar></div>")
      bar = DOM.query_selector(doc, "x-bar")

      DOM.define_element(doc, "x-bar", reporting_def(self(), observed: ["y"]))

      # synchronous upgrade during define: constructed, then attributeChanged for the
      # existing observed attr (old = nil), then connected (it is in the tree).
      assert_received {:constructed, id}
      assert id == bar.node_id
      assert_received {:attr, "y", nil, "2"}
      assert_received {:connected, ^id}
    end
  end

  describe ":defined pseudo-class" do
    test "a defined custom element matches :defined; an undefined one does not" do
      doc = new_document("<div id='p'><x-known></x-known><x-unknown></x-unknown></div>")
      DOM.define_element(doc, "x-known", %Def{})

      assert DOM.Element.matches(DOM.query_selector(doc, "x-known"), ":defined")
      refute DOM.Element.matches(DOM.query_selector(doc, "x-unknown"), ":defined")
    end

    test "a built-in element matches :defined" do
      doc = new_document("<div id='p'></div>")
      assert DOM.Element.matches(DOM.query_selector(doc, "#p"), ":defined")
    end
  end
end
