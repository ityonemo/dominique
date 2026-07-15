defmodule Integration.CustomElementTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.CustomElementDefinition, as: Def
  alias DOM.Element
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/custom-elements.html"

    # The synchronous lifecycle: create (ctor/constructed), setAttribute
    # (attributeChanged), append (connected), remove (disconnected) — each reaction
    # fires during its trigger, interleaved with markers. Then an upgrade: define on
    # an already-inserted element runs constructed, attributeChanged for existing
    # observed attrs, connected. We reproduce the same trace in Elixir.
    @js """
    return await page.evaluate(() => {
      const uniq = "x-" + Math.random().toString(36).slice(2);
      const log = [];

      class Foo extends HTMLElement {
        static get observedAttributes() { return ["x"]; }
        constructor() { super(); log.push("constructed"); }
        connectedCallback() { log.push("connected"); }
        disconnectedCallback() { log.push("disconnected"); }
        attributeChangedCallback(n, o, v) { log.push(`attr:${n}:${o}:${v}`); }
      }
      customElements.define(uniq, Foo);

      const el = document.createElement(uniq);
      log.push("--created--");
      el.setAttribute("x", "1");
      log.push("--attr--");
      document.body.appendChild(el);
      log.push("--appended--");
      document.body.removeChild(el);
      log.push("--removed--");

      // upgrade path
      const uniq2 = "x-" + Math.random().toString(36).slice(2);
      const host = document.createElement("div");
      host.innerHTML = `<${uniq2} y='2'></${uniq2}>`;
      document.body.appendChild(host);
      log.push("--host-inserted--");
      class Bar extends HTMLElement {
        static get observedAttributes() { return ["y"]; }
        constructor() { super(); log.push("u:constructed"); }
        connectedCallback() { log.push("u:connected"); }
        attributeChangedCallback(n,o,v) { log.push(`u:attr:${n}:${o}:${v}`); }
      }
      customElements.define(uniq2, Bar);
      log.push("--defined--");

      return log;
    });
    """

    test "custom element lifecycle + upgrade order matches the browser", %{js: expected} do
      doc = DOM.new("<div id='body'></div>")
      body = DOM.query_selector(doc, "#body")
      parent = self()

      # collect into an ordered agent (reactions are synchronous, so simple append)
      {:ok, log} = Agent.start_link(fn -> [] end)
      put = fn tag -> Agent.update(log, &[tag | &1]) end

      foo = %Def{
        observed_attributes: ["x"],
        constructed: fn _ -> put.("constructed") end,
        connected: fn _ -> put.("connected") end,
        disconnected: fn _ -> put.("disconnected") end,
        attribute_changed: fn _, n, o, v -> put.("attr:#{n}:#{fmt(o)}:#{fmt(v)}") end
      }

      DOM.define_element(doc, "x-foo", foo)

      el = DOM.create_element(doc, "x-foo")
      put.("--created--")
      Element.set_attribute(el, "x", "1")
      put.("--attr--")
      Node.append_child(body, el)
      put.("--appended--")
      Node.remove_child(body, el)
      put.("--removed--")

      # upgrade path
      host = DOM.create_element(doc, "div")
      Element.set_inner_html(host, "<x-bar y='2'></x-bar>")
      Node.append_child(body, host)
      put.("--host-inserted--")

      bar = %Def{
        observed_attributes: ["y"],
        constructed: fn _ -> put.("u:constructed") end,
        connected: fn _ -> put.("u:connected") end,
        attribute_changed: fn _, n, o, v -> put.("u:attr:#{n}:#{fmt(o)}:#{fmt(v)}") end
      }

      DOM.define_element(doc, "x-bar", bar)
      put.("--defined--")

      _ = parent
      log_list = Agent.get(log, &Enum.reverse/1)
      assert log_list == expected
    end

    # JS null renders as "null" in the browser template string.
    defp fmt(nil), do: "null"
    defp fmt(v), do: v
  end
end
