defmodule Integration.AbortSignalTest do
  use ExUnit.Case, async: true
  use Playwright

  alias DOM.AbortController
  alias DOM.AbortSignal
  alias DOM.Event
  alias DOM.Node

  @moduletag :integration

  playwright do
    @link "https://dom.spec.whatwg.org/#interface-AbortController"

    @js """
    return await page.evaluate(() => {
      const el = document.createElement("div");
      const controller = new AbortController();
      const signal = controller.signal;
      let count = 0;

      el.addEventListener("ping", () => count++, { signal });

      const beforeAbort = signal.aborted;
      el.dispatchEvent(new Event("ping"));   // fires -> 1
      controller.abort();                    // removes the listener
      el.dispatchEvent(new Event("ping"));   // no longer fires

      return { beforeAbort, afterAbort: signal.aborted, count };
    });
    """

    test "the {signal} option removes the listener when the controller aborts", %{js: expected} do
      document = DOM.new()
      el = DOM.create_element(document, "div")
      controller = AbortController.new(document)
      signal = AbortController.signal(controller)

      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Node.add_event_listener(el, "ping", fn _ -> Agent.update(agent, &(&1 + 1)) end,
        signal: signal
      )

      before_abort = AbortSignal.aborted?(signal)
      Node.dispatch_event(el, Event.new("ping"))
      AbortController.abort(controller)
      Node.dispatch_event(el, Event.new("ping"))

      result = %{
        "beforeAbort" => before_abort,
        "afterAbort" => AbortSignal.aborted?(signal),
        "count" => Agent.get(agent, & &1)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const controller = new AbortController();
      const signal = controller.signal;
      let fired = 0;

      signal.addEventListener("abort", () => fired++);
      controller.abort("boom");

      return { fired, reasonMatches: signal.reason === "boom", aborted: signal.aborted };
    });
    """

    test "aborting fires the signal's abort event and records the reason", %{js: expected} do
      document = DOM.new()
      controller = AbortController.new(document)
      signal = AbortController.signal(controller)

      {:ok, agent} = Agent.start_link(fn -> 0 end)
      AbortSignal.add_event_listener(signal, "abort", fn _ -> Agent.update(agent, &(&1 + 1)) end)
      AbortController.abort(controller, "boom")

      result = %{
        "fired" => Agent.get(agent, & &1),
        "reasonMatches" => AbortSignal.reason(signal) == "boom",
        "aborted" => AbortSignal.aborted?(signal)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const c1 = new AbortController();
      const c2 = new AbortController();
      const any = AbortSignal.any([c1.signal, c2.signal]);

      const before = any.aborted;
      c2.abort("from2");             // any aborts as soon as a source does
      return { before, after: any.aborted, reason: any.reason };
    });
    """

    test "AbortSignal.any aborts when any source aborts, adopting its reason", %{js: expected} do
      document = DOM.new()
      c1 = AbortController.new(document)
      c2 = AbortController.new(document)
      any = AbortSignal.any(document, [AbortController.signal(c1), AbortController.signal(c2)])

      before = AbortSignal.aborted?(any)
      AbortController.abort(c2, "from2")

      result = %{
        "before" => before,
        "after" => AbortSignal.aborted?(any),
        "reason" => AbortSignal.reason(any)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const c = new AbortController();
      c.abort("already");
      const any = AbortSignal.any([c.signal]);   // source already aborted
      return { bornAborted: any.aborted, reason: any.reason };
    });
    """

    test "AbortSignal.any over an already-aborted source is born aborted", %{js: expected} do
      document = DOM.new()
      c = AbortController.new(document)
      AbortController.abort(c, "already")
      any = AbortSignal.any(document, [AbortController.signal(c)])

      result = %{
        "bornAborted" => AbortSignal.aborted?(any),
        "reason" => AbortSignal.reason(any)
      }

      assert result == expected
    end

    @js """
    return await page.evaluate(() => {
      const c = new AbortController();
      c.signal.addEventListener("abort", () => {});   // listener that is never fired/swept
      return { aborted: c.signal.aborted };
    });
    """

    test "an un-aborted signal's abort listener leaves consistent state", %{js: expected} do
      # Regression: signal listener rows are keyed by the signal ref, not a node id.
      # check_consistency! (run on_exit) must tolerate them without an abort sweeping them.
      document = DOM.new()
      controller = AbortController.new(document)
      signal = AbortController.signal(controller)
      AbortSignal.add_event_listener(signal, "abort", fn _ -> :noop end)

      # The consistency net must accept the (node-less) signal listener row.
      assert DOM._check_index_consistency!(document.server) == :ok
      assert %{"aborted" => AbortSignal.aborted?(signal)} == expected
    end

    @js """
    return await page.evaluate(async () => {
      const signal = AbortSignal.timeout(20);
      const before = signal.aborted;
      await new Promise(r => setTimeout(r, 60));   // let the timeout fire
      return { before, after: signal.aborted };
    });
    """

    test "AbortSignal.timeout aborts after its delay", %{js: expected} do
      document = DOM.new()
      signal = AbortSignal.timeout(document, 20)
      before = AbortSignal.aborted?(signal)

      # Poll until the BEAM timer delivers to the server and the abort runs.
      after_value = eventually(fn -> AbortSignal.aborted?(signal) end)

      result = %{"before" => before, "after" => after_value}
      assert result == expected
    end
  end

  # Poll `fun` until it returns true (or give up after ~1s) — waits for the async
  # timeout abort to land without a fixed sleep.
  defp eventually(fun, tries \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end
end
