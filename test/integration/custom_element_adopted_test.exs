defmodule Integration.CustomElementAdoptedTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.CustomElementDefinition, as: Def
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/custom-elements.html#custom-element-conformance"

    # An element retains its definition across adoption: adopting into a document
    # whose registry never registered the name STILL fires disconnected (source) then
    # adopted, keeps the element :defined, and fires connected on re-insertion — even
    # though the destination has no registration. We reproduce the same trace in
    # Dominique (definitions ride on the element record).
    @js """
    return await page.evaluate(() => {
      const name = "x-" + Math.random().toString(36).slice(2);
      const log = [];
      class Foo extends HTMLElement {
        connectedCallback(){ log.push("connected"); }
        disconnectedCallback(){ log.push("disconnected"); }
        adoptedCallback(o, n){ log.push("adopted:" + (o === document) + ":" + (n !== document)); }
      }
      customElements.define(name, Foo);
      const el = document.createElement(name);
      document.body.appendChild(el);
      log.push("--connected-doc1--");

      const iframe = document.createElement("iframe");
      document.body.appendChild(iframe);
      const doc2 = iframe.contentDocument;          // separate window, EMPTY registry
      const adopted = doc2.adoptNode(el);           // disconnected (doc1) + adopted
      log.push("--adopted--");
      log.push("defined:" + adopted.matches(":defined"));
      doc2.body.appendChild(adopted);               // connected, though doc2 undefines it
      log.push("--reinserted--");
      return log;
    });
    """

    test "an element keeps its definition across adoption into an undefined-in-dst document",
         %{js: expected} do
      src = DOM.new("<div id='s'></div>")
      dst = DOM.new("<div id='d'></div>")
      s = DOM.query_selector(src, "#s")
      d = DOM.query_selector(dst, "#d")
      parent = self()
      {:ok, log} = Agent.start_link(fn -> [] end)
      put = fn tag -> Agent.update(log, &[tag | &1]) end

      # only the SOURCE defines the name
      def = %Def{
        connected: fn _ -> put.("connected") end,
        disconnected: fn _ -> put.("disconnected") end,
        adopted: fn _, o, n ->
          put.("adopted:#{o.node_id == src.node_id}:#{n.node_id == dst.node_id}")
        end
      }

      DOM.define_element(src, "x-foo", def)
      foo = DOM.create_element(src, "x-foo")
      Node.append_child(s, foo)
      put.("--connected-doc1--")

      adopted = DOM.adopt_node(dst, foo)
      put.("--adopted--")
      put.("defined:#{DOM.Element.matches(adopted, ":defined")}")
      Node.append_child(d, adopted)
      put.("--reinserted--")

      _ = parent
      assert Agent.get(log, &Enum.reverse/1) == expected
    end
  end
end
