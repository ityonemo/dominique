defmodule DOM.CSS.CombinatorQueryCountTest do
  use ExUnit.Case, async: true

  alias DOM.Element

  # Regression: the combinator engine must NOT re-query the leftward compound per subject
  # candidate (the descendant/child N+1 that this rewrite removed). We trace :ets.select
  # during a combinator query and count only the COMBINATOR-ENGINE selects (id/class/span
  # match specs) — that count must be CONSTANT in the candidate count. The candidate-gathering
  # walk (descendant_ids) scales with the tree and is counted separately / ignored.

  # Build `#foo` containing `n` `.bar` spans, each nested a couple levels deep (so a walk
  # would have ancestor chains to re-traverse).
  defp build_descendant_tree(n) do
    doc = DOM.new()
    foo = DOM.create_element(doc, "div")
    Element.set_attribute(foo, "id", "foo")
    append(doc, foo)

    for _ <- 1..n do
      a = DOM.create_element(doc, "div")
      b = DOM.create_element(doc, "div")
      bar = DOM.create_element(doc, "span")
      Element.set_attribute(bar, "class", "bar")
      append(b, bar)
      append(a, b)
      append(foo, a)
    end

    doc
  end

  defp append(parent, child), do: DOM.Node.append_child(parent, child)

  # Count :ets.select calls made by `doc`'s server during `query`, split into
  # combinator-engine selects (match spec mentions :id/:class/:span/map_get) vs the rest.
  defp engine_select_count(doc, query) do
    server = doc.server
    :erlang.trace(server, true, [:call])
    :erlang.trace_pattern({:ets, :select, :_}, true, [:global])
    :erlang.trace_pattern({:ets, :select_reverse, :_}, true, [:global])

    DOM.query_selector_all(doc, query)
    Process.sleep(30)
    :erlang.trace(server, false, [:call])

    Stream.repeatedly(fn ->
      receive do
        msg -> msg
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.count(fn
      {:trace, _, :call, {:ets, sel, args}} when sel in [:select, :select_reverse] ->
        spec = args |> Enum.at(1) |> inspect()

        String.contains?(spec, ":id") or String.contains?(spec, ":class") or
          String.contains?(spec, ":span") or String.contains?(spec, "map_get")

      _ ->
        false
    end)
  end

  test "descendant combinator: engine selects are constant in candidate count" do
    small = engine_select_count(build_descendant_tree(10), "#foo .bar")
    large = engine_select_count(build_descendant_tree(200), "#foo .bar")

    # The N+1 would make `large` scale with 200; the sweep keeps it flat.
    assert small == large
    # And it's a small constant (subject match + left match + 2 extent resolutions).
    assert small <= 8
  end

  test "child combinator: engine selects are constant in candidate count" do
    tree = fn n ->
      doc = DOM.new()
      ul = DOM.create_element(doc, "ul")
      Element.set_attribute(ul, "id", "list")
      append(doc, ul)

      for _ <- 1..n do
        li = DOM.create_element(doc, "li")
        Element.set_attribute(li, "class", "item")
        append(ul, li)
      end

      doc
    end

    assert engine_select_count(tree.(10), "#list > .item") ==
             engine_select_count(tree.(200), "#list > .item")
  end
end
