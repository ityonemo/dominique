defmodule Integration.ShadowTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element

  @moduletag :integration

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/shadow-dom"

    # attachShadow + shadowRoot: open exposes the root, closed hides it (shadowRoot
    # is null), and node type/name match a fragment.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='open'></div><div id='closed'></div>", "text/html");
      const o = doc.getElementById("open");
      const c = doc.getElementById("closed");
      const so = o.attachShadow({ mode: "open" });
      c.attachShadow({ mode: "closed" });
      return {
        open_type: so.nodeType,
        open_name: so.nodeName,
        open_exposed: o.shadowRoot !== null,
        closed_exposed: c.shadowRoot !== null
      };
    });
    """

    test "attachShadow / shadowRoot open vs closed match the browser", %{js: expected} do
      doc = DOM.new("<div id='open'></div><div id='closed'></div>")
      o = DOM.query_selector(doc, "#open")
      c = DOM.query_selector(doc, "#closed")

      so = Element.attach_shadow(o, :open)
      Element.attach_shadow(c, :closed)

      result = %{
        "open_type" => DOM.Node.node_type(so),
        "open_name" => DOM.Node.node_name(so),
        "open_exposed" => Element.shadow_root(o) != nil,
        "closed_exposed" => Element.shadow_root(c) != nil
      }

      assert result == expected
    end
  end

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/shadow-dom"

    # Shadow innerHTML round-trips, and the host's outerHTML/innerHTML exclude the
    # shadow tree entirely.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString("<div id='d'>light</div>", "text/html");
      const d = doc.getElementById("d");
      const s = d.attachShadow({ mode: "open" });
      s.innerHTML = "<p>shadow</p><span>x</span>";
      return {
        shadow_html: s.innerHTML,
        host_outer: d.outerHTML,
        host_inner: d.innerHTML
      };
    });
    """

    test "shadow innerHTML round-trips and the host excludes it", %{js: expected} do
      doc = DOM.new("<div id='d'>light</div>")
      d = DOM.query_selector(doc, "#d")
      s = Element.attach_shadow(d, :open)
      DOM.ShadowRoot.set_inner_html(s, "<p>shadow</p><span>x</span>")

      result = %{
        "shadow_html" => DOM.ShadowRoot.inner_html(s),
        "host_outer" => Element.outer_html(d),
        "host_inner" => Element.inner_html(d)
      }

      assert result == expected
    end
  end

  playwright do
    @link "https://github.com/web-platform-tests/wpt/tree/master/shadow-dom"

    # Slot assignment: default + named slots, host order, assignedNodes/assignedSlot.
    @js """
    return await page.evaluate(() => {
      const doc = new DOMParser().parseFromString(
        "<div id='host'><a slot='x'>1</a><b>2</b><c slot='x'>3</c></div>", "text/html");
      const host = doc.getElementById("host");
      const s = host.attachShadow({ mode: "open" });
      s.innerHTML = "<slot name='x'></slot><slot></slot>";
      const [named, def] = s.querySelectorAll("slot");
      const tags = (ns) => Array.from(ns, n => n.nodeName.toLowerCase());
      const a = host.querySelector("a");
      return {
        named: tags(named.assignedNodes()),
        default: tags(def.assignedNodes()),
        a_slot: a.assignedSlot ? a.assignedSlot.getAttribute("name") : null
      };
    });
    """

    test "slot assignment matches the browser", %{js: expected} do
      doc = DOM.new("<div id='host'><a slot='x'>1</a><b>2</b><c slot='x'>3</c></div>")
      host = DOM.query_selector(doc, "#host")
      s = Element.attach_shadow(host, :open)
      DOM.ShadowRoot.set_inner_html(s, "<slot name='x'></slot><slot></slot>")
      [named, def] = DOM.query_selector_all(s, "slot")
      a = DOM.query_selector(doc, "a")

      tags = fn ns -> Enum.map(ns, &String.downcase(DOM.Node.node_name(&1))) end

      result = %{
        "named" => tags.(DOM.Slot.assigned_nodes(named)),
        "default" => tags.(DOM.Slot.assigned_nodes(def)),
        "a_slot" =>
          case DOM.Node.assigned_slot(a) do
            nil -> nil
            slot -> Element.get_attribute(slot, "name")
          end
      }

      assert result == expected
    end
  end
end
