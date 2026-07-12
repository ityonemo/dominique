defmodule Integration.MutationObserverTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Element
  alias DOM.MutationObserver
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#interface-mutationobserver"

    # A batched callback (one call, N records) fired as a microtask, with the record
    # shapes for childList / attributes(+oldValue) / characterData(+oldValue). We
    # build the same observations + mutations in Elixir and compare the record batch.
    @js """
    return await page.evaluate(async () => {
      const doc = new DOMParser().parseFromString(
        "<div id='p' data-x='old'><b id='ref'></b>hi</div>", "text/html");
      const p = doc.getElementById("p");
      const ref = doc.getElementById("ref");
      const text = p.lastChild;

      let batch = null;
      const mo = new MutationObserver(records => { batch = records; });
      mo.observe(p, {childList: true, attributes: true, attributeOldValue: true,
                     characterData: true, characterDataOldValue: true, subtree: true});

      const a = doc.createElement("a");
      p.insertBefore(a, ref);          // childList: add a before ref
      p.setAttribute("data-x", "new"); // attributes: data-x, old "old"
      text.data = "bye";               // characterData: old "hi"
      await Promise.resolve();

      // Dominique's nodeName is lowercase for HTML elements (a separate divergence
      // from the uppercase DOM quirk); this test is about MutationObserver, not
      // casing, so lowercase both sides.
      const nn = (n) => n.nodeName.toLowerCase();
      return batch.map(r => ({
        type: r.type,
        target: nn(r.target),
        attr: r.attributeName || null,
        oldValue: r.oldValue ?? null,
        added: Array.from(r.addedNodes, nn),
        prev: r.previousSibling ? nn(r.previousSibling) : null,
        next: r.nextSibling ? (r.nextSibling.id || nn(r.nextSibling)) : null,
      }));
    });
    """

    test "batched record shapes match the browser", %{js: expected} do
      doc =
        DOM.new("<div id='p' data-x='old'><b id='ref'></b>hi</div>")

      p = DOM.query_selector(doc, "#p")
      ref = DOM.query_selector(doc, "#ref")
      [_b, text] = Node.child_nodes(p)

      parent = self()
      mo = MutationObserver.new(doc, fn records -> send(parent, {:records, records}) end)

      MutationObserver.observe(mo, p,
        child_list: true,
        attributes: true,
        attribute_old_value: true,
        character_data: true,
        character_data_old_value: true,
        subtree: true
      )

      # one task = one batch (matches the browser's synchronous run of the three)
      DOM.lambda(doc.server, fn ->
        a = DOM.create_element(doc, "a")
        Node.insert_before(p, a, ref)
        Element.set_attribute(p, "data-x", "new")
        Node.set_text_content(text, "bye")
      end)

      records =
        receive do
          {:records, records} -> records
        after
          200 -> flunk("no MutationObserver callback")
        end

      shaped =
        Enum.map(records, fn r ->
          %{
            "type" => Atom.to_string(r.type) |> camelize(),
            "target" => Node.node_name(r.target),
            "attr" => r.attribute_name,
            "oldValue" => r.old_value,
            "added" => Enum.map(r.added_nodes, &Node.node_name/1),
            "prev" => r.previous_sibling && Node.node_name(r.previous_sibling),
            "next" =>
              r.next_sibling &&
                (Element.get_attribute(r.next_sibling, "id") || Node.node_name(r.next_sibling))
          }
        end)

      assert shaped == expected
    end

    # :child_list -> "childList", :character_data -> "characterData", etc.
    defp camelize("child_list"), do: "childList"
    defp camelize("character_data"), do: "characterData"
    defp camelize(other), do: other
  end
end
