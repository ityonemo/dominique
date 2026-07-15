defmodule Integration.FocusEventTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.Event
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/interaction.html#focus-update-steps"

    # The full focus-event sequence + flags + relatedTarget, moving focus nothing->A,
    # A->B, then blur B. We record the same trace in Elixir and compare.
    @js """
    return await page.evaluate(() => {
      const host = document.createElement("div");
      host.innerHTML = "<input id='a'><input id='b'>";
      document.body.appendChild(host);
      const a = host.querySelector("#a"), b = host.querySelector("#b");
      const log = [];
      const mark = (id, e) =>
        log.push(`${e.type}@${id}:tgt=${e.target.id}:rel=${e.relatedTarget?e.relatedTarget.id:"-"}:bub=${e.bubbles}:comp=${e.composed}`);
      for (const [el,id] of [[a,"a"],[b,"b"]])
        for (const t of ["focus","blur","focusin","focusout"])
          el.addEventListener(t, (e) => mark(id, e));

      a.focus();
      b.focus();
      b.blur();
      document.body.removeChild(host);
      return log;
    });
    """

    test "focus event sequence + flags + relatedTarget match the browser", %{js: expected} do
      doc = DOM.new("<body><input id='a'><input id='b'></body>")
      a = DOM.query_selector(doc, "#a")
      b = DOM.query_selector(doc, "#b")
      {:ok, log} = Agent.start_link(fn -> [] end)

      eid = fn node -> DOM.Element.get_attribute(node, "id") end

      for {node, id} <- [{a, "a"}, {b, "b"}], type <- ~w(focus blur focusin focusout) do
        Node.add_event_listener(node, type, fn %Event{} = e ->
          # Build the line HERE (in the server process, where get_attribute forks
          # re-entrantly). Doing get_attribute inside Agent.update would run it in the
          # Agent process (self() != server) and deadlock the busy server.
          rel = if e.related_target, do: eid.(e.related_target), else: "-"

          line =
            "#{e.type}@#{id}:tgt=#{eid.(e.target)}:rel=#{rel}:bub=#{e.bubbles}:comp=#{e.composed}"

          Agent.update(log, &[line | &1])
        end)
      end

      Node.focus(a)
      Node.focus(b)
      Node.blur(b)

      assert Agent.get(log, &Enum.reverse/1) == expected
    end
  end
end
