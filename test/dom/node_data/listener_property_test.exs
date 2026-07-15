defmodule DOM.NodeData.ListenerPropertyTest do
  use ExUnit.Case, async: true

  # E1: the :listener index-row family. Storage/retrieval/removal invariants of the
  # Table primitives, independent of dispatch (E2+). A listener row is
  #   {{:listener, node_id, seq}, %DOM.Listener{type, fn, capture, once, passive}}
  # registration order (seq) is preserved, which is the DOM's listener fire order.

  alias DOM.Listener
  alias DOM.NodeData.IndexTable

  setup do
    index = :ets.new(:index, [:ordered_set, :private])
    # listener_put allocates its seq from the `:listener_seq` atomic counter that
    # DOM.init stashes in the process dict; provide one for these serverless tests.
    Process.put(:listener_seq, :counters.new(1, []))
    %{index: index, node: make_ref()}
  end

  defp listener(type, fun, opts \\ []) do
    %Listener{
      type: type,
      fn: fun,
      capture: Keyword.get(opts, :capture, false),
      once: Keyword.get(opts, :once, false),
      passive: Keyword.get(opts, :passive, false)
    }
  end

  test "listeners_of returns rows in registration order", %{index: index, node: node} do
    a = listener("click", fn -> :a end)
    b = listener("click", fn -> :b end)
    c = listener("mouseover", fn -> :c end)

    IndexTable.listener_put(index, node, a)
    IndexTable.listener_put(index, node, b)
    IndexTable.listener_put(index, node, c)

    assert IndexTable.listeners_of(index, node) == [a, b, c]
  end

  test "listeners_of is per-node", %{index: index, node: node} do
    other = make_ref()
    a = listener("click", fn -> :a end)
    b = listener("click", fn -> :b end)

    IndexTable.listener_put(index, node, a)
    IndexTable.listener_put(index, other, b)

    assert IndexTable.listeners_of(index, node) == [a]
    assert IndexTable.listeners_of(index, other) == [b]
  end

  test "listener_delete matches on (type, fn, capture)", %{index: index, node: node} do
    fun = fn -> :x end
    a = listener("click", fun, capture: false)
    b = listener("click", fun, capture: true)

    IndexTable.listener_put(index, node, a)
    IndexTable.listener_put(index, node, b)

    # deleting the non-capture one leaves the capture one
    IndexTable.listener_delete(index, node, "click", fun, false)
    assert IndexTable.listeners_of(index, node) == [b]
  end

  test "listener_delete is a no-op when nothing matches", %{index: index, node: node} do
    a = listener("click", fn -> :a end)
    IndexTable.listener_put(index, node, a)

    IndexTable.listener_delete(index, node, "click", fn -> :other end, false)
    assert IndexTable.listeners_of(index, node) == [a]
  end

  test "listeners_retract drops all rows for a node", %{index: index, node: node} do
    IndexTable.listener_put(index, node, listener("click", fn -> :a end))
    IndexTable.listener_put(index, node, listener("keydown", fn -> :b end))

    IndexTable.listeners_retract(index, node)
    assert IndexTable.listeners_of(index, node) == []
  end

  test "listeners_of is empty for a node with none", %{index: index, node: node} do
    assert IndexTable.listeners_of(index, node) == []
  end
end
