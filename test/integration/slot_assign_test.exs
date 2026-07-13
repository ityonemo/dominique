defmodule Integration.SlotAssignTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.Node
  alias DOM.ShadowRoot
  alias DOM.Slot

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#dom-slotable-assignedslot"

    # Manual slot assignment: assign() sets the assigned nodes (host children only),
    # replaces on re-assign, clears with no args. We build the same manual shadow and
    # compare assignedNodes at each step.
    @js """
    return await page.evaluate(() => {
      const host = document.createElement("div");
      host.innerHTML = "<a id='a'>1</a><b id='b'>2</b><c id='c'>3</c>";
      document.body.appendChild(host);
      const sr = host.attachShadow({mode: "open", slotAssignment: "manual"});
      sr.innerHTML = "<slot></slot>";
      const slot = sr.querySelector("slot");
      const a = host.querySelector("#a"), b = host.querySelector("#b"), c = host.querySelector("#c");
      const ids = () => slot.assignedNodes().map(n => n.id);
      const stray = document.createElement("z");   // not a host child

      const steps = {};
      steps.before = ids();
      slot.assign(a, c);
      steps.assigned = ids();
      slot.assign(c, b);
      steps.reassigned = ids();
      slot.assign(a, stray);   // stray isn't a host child
      steps.filtered = ids();
      slot.assign();
      steps.cleared = ids();

      document.body.removeChild(host);
      return steps;
    });
    """

    test "manual slot assignment matches the browser", %{js: expected} do
      doc = DOM.new("<div id='host'><a id='a'>1</a><b id='b'>2</b><c id='c'>3</c></div>")
      host = DOM.query_selector(doc, "#host")
      shadow = Element.attach_shadow(host, :open, slot_assignment: :manual)
      ShadowRoot.set_inner_html(shadow, "<slot></slot>")
      [slot] = Node.child_nodes(shadow)

      a = DOM.query_selector(doc, "#a")
      b = DOM.query_selector(doc, "#b")
      c = DOM.query_selector(doc, "#c")
      stray = DOM.create_element(doc, "z")
      ids = fn -> Enum.map(Slot.assigned_nodes(slot), &Element.get_attribute(&1, "id")) end

      steps = %{"before" => ids.()}
      Slot.assign(slot, [a, c])
      steps = Map.put(steps, "assigned", ids.())
      Slot.assign(slot, [c, b])
      steps = Map.put(steps, "reassigned", ids.())
      Slot.assign(slot, [a, stray])
      steps = Map.put(steps, "filtered", ids.())
      Slot.assign(slot, [])
      steps = Map.put(steps, "cleared", ids.())

      assert steps == expected
    end
  end
end
