defmodule Integration.TimerTest do
  use ExUnit.Case, async: true
  use Playwright

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html"

    # The event loop in one trace: sync runs to completion, ALL microtasks drain
    # before any task, each timer is its own task, and a microtask enqueued inside a
    # timer drains before the next task. We build the same sequence in Elixir; a
    # collector records the order tags arrive.
    @js """
    return await page.evaluate(async () => {
      const log = [];
      log.push("sync-start");
      setTimeout(() => { log.push("timer1"); queueMicrotask(() => log.push("micro-in-timer1")); }, 0);
      setTimeout(() => log.push("timer2"), 0);
      queueMicrotask(() => log.push("micro-sync"));
      log.push("sync-end");
      await new Promise(r => setTimeout(r, 30));
      return log;
    });
    """

    test "task vs microtask ordering matches the browser", %{js: expected} do
      doc = DOM.new("<div></div>")
      parent = self()
      tag = fn t -> send(parent, t) end

      # The browser's whole scheduling block is ONE synchronous task whose microtasks
      # drain at its end. In Dominique a single server task is one DOM.lambda — so we
      # run the sync scheduling inside one lambda; its microtask checkpoint drains
      # micro-sync after the body, then the timer tasks fire.
      DOM.lambda(doc.server, fn ->
        tag.("sync-start")

        DOM.set_timeout(
          doc,
          fn ->
            tag.("timer1")
            DOM._enqueue_microtask(doc.server, fn -> tag.("micro-in-timer1") end)
          end,
          0
        )

        DOM.set_timeout(doc, fn -> tag.("timer2") end, 0)
        DOM._enqueue_microtask(doc.server, fn -> tag.("micro-sync") end)
        tag.("sync-end")
      end)

      log = collect(6, 300)
      assert log == expected
    end

    @link "https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html"

    # setInterval repeats until cleared; clearing inside the callback on the Nth tick
    # yields exactly N ticks. Same shape in both.
    @js """
    return await page.evaluate(async () => {
      const log = [];
      let count = 0;
      const id = setInterval(() => {
        count++;
        log.push(count);
        if (count === 3) clearInterval(id);
      }, 10);
      await new Promise(r => setTimeout(r, 120));
      return log;
    });
    """

    test "setInterval repeats then self-clears, matching the browser", %{js: expected} do
      doc = DOM.new("<div></div>")
      parent = self()
      counter = :counters.new(1, [])
      {:ok, holder} = Agent.start_link(fn -> nil end)

      id =
        DOM.set_interval(
          doc,
          fn ->
            n = :counters.get(counter, 1) + 1
            :counters.add(counter, 1, 1)
            send(parent, {:tick, n})
            if n == 3, do: DOM.clear_interval(doc, Agent.get(holder, & &1))
          end,
          10
        )

      Agent.update(holder, fn _ -> id end)

      log = collect_ticks(100)
      assert log == expected
    end

    defp collect(0, _timeout), do: []

    defp collect(n, timeout) do
      receive do
        tag -> [tag | collect(n - 1, timeout)]
      after
        timeout -> []
      end
    end

    defp collect_ticks(timeout) do
      receive do
        {:tick, n} -> [n | collect_ticks(timeout)]
      after
        timeout -> []
      end
    end
  end
end
