defmodule DOM.MutationObserverTest do
  use DOM.Case, async: true

  # MutationObserver: observe a node (optionally its subtree) and receive batched
  # MutationRecords in a callback run as a MICROTASK after the mutating task.
  # Browser-verified semantics recorded in the mutation-observer-semantics memory.

  alias DOM.Element
  alias DOM.MutationObserver
  alias DOM.MutationRecord
  alias DOM.Node

  # An observer whose callback forwards its record batch to the test process.
  defp observer(doc) do
    parent = self()
    MutationObserver.new(doc, fn records -> send(parent, {:records, records}) end)
  end

  # Block for the callback's record batch (it fires during the checkpoint AFTER the
  # mutating call replies — an async microtask), or [] if none arrives.
  defp await_records do
    receive do
      {:records, records} -> records
    after
      100 -> []
    end
  end

  describe "childList" do
    test "an append produces a childList record after the task (batched, async)" do
      doc = new_document("<div id='p'></div>")
      p = DOM.query_selector(doc, "#p")
      mo = observer(doc)
      MutationObserver.observe(mo, p, child_list: true)

      a = DOM.create_element(doc, "a")
      Node.append_child(p, a)

      assert [%MutationRecord{} = rec] = await_records()
      assert rec.type == :child_list
      assert rec.target.node_id == p.node_id
      assert Enum.map(rec.added_nodes, & &1.node_id) == [a.node_id]
      assert rec.removed_nodes == []
    end

    test "multiple mutations in one task batch into ONE callback with N records" do
      doc = new_document("<div id='p'></div>")
      p = DOM.query_selector(doc, "#p")
      mo = observer(doc)
      MutationObserver.observe(mo, p, child_list: true, attributes: true)

      # one task = one DOM.lambda: two appends + an attribute change -> 3 records
      DOM.lambda(doc.server, fn ->
        Node.append_child(p, DOM.create_element(doc, "a"))
        Node.append_child(p, DOM.create_element(doc, "b"))
        Element.set_attribute(p, "x", "1")
      end)

      records = await_records()
      assert length(records) == 3
      assert Enum.map(records, & &1.type) == [:child_list, :child_list, :attributes]
      # no second callback
      assert await_records() == []
    end

    test "previous/next sibling bracket the change" do
      doc = new_document("<div id='p'><b id='ref'></b></div>")
      p = DOM.query_selector(doc, "#p")
      ref = DOM.query_selector(doc, "#ref")
      mo = observer(doc)
      MutationObserver.observe(mo, p, child_list: true)

      a = DOM.create_element(doc, "a")
      Node.insert_before(p, a, ref)

      assert [rec] = await_records()
      assert rec.previous_sibling == nil
      assert rec.next_sibling.node_id == ref.node_id
    end

    test "subtree observes a descendant mutation" do
      doc = new_document("<div id='root'><span id='mid'></span></div>")
      root = DOM.query_selector(doc, "#root")
      mid = DOM.query_selector(doc, "#mid")
      mo = observer(doc)
      MutationObserver.observe(mo, root, child_list: true, subtree: true)

      Node.append_child(mid, DOM.create_element(doc, "a"))

      assert [rec] = await_records()
      assert rec.target.node_id == mid.node_id
    end
  end

  describe "attributes" do
    test "an attribute change records name and (with old value) the prior value" do
      doc = new_document("<div id='p' data-x='old'></div>")
      p = DOM.query_selector(doc, "#p")
      mo = observer(doc)
      MutationObserver.observe(mo, p, attributes: true, attribute_old_value: true)

      Element.set_attribute(p, "data-x", "new")

      assert [rec] = await_records()
      assert rec.type == :attributes
      assert rec.attribute_name == "data-x"
      assert rec.old_value == "old"
    end

    test "attribute_filter limits which attributes record" do
      doc = new_document("<div id='p'></div>")
      p = DOM.query_selector(doc, "#p")
      mo = observer(doc)
      MutationObserver.observe(mo, p, attributes: true, attribute_filter: ["keep"])

      DOM.lambda(doc.server, fn ->
        Element.set_attribute(p, "skip", "1")
        Element.set_attribute(p, "keep", "2")
      end)

      records = await_records()
      assert Enum.map(records, & &1.attribute_name) == ["keep"]
    end
  end

  describe "characterData" do
    test "a text data change records the old value" do
      doc = new_document("<div id='p'>hello</div>")
      p = DOM.query_selector(doc, "#p")
      [text] = Node.child_nodes(p)
      mo = observer(doc)
      MutationObserver.observe(mo, text, character_data: true, character_data_old_value: true)

      Node.set_text_content(text, "world")

      assert [rec] = await_records()
      assert rec.type == :character_data
      assert rec.old_value == "hello"
    end
  end

  describe "takeRecords / disconnect" do
    test "take_records returns queued records synchronously and prevents the callback" do
      doc = new_document("<div id='p'></div>")
      p = DOM.query_selector(doc, "#p")
      mo = observer(doc)
      MutationObserver.observe(mo, p, child_list: true)

      # Within one task: append queues a record, then take_records returns it and
      # clears the queue — so the notify callback afterward delivers nothing.
      taken =
        DOM.lambda(doc.server, fn ->
          Node.append_child(p, DOM.create_element(doc, "a"))
          MutationObserver.take_records(mo)
        end)

      assert [%MutationRecord{type: :child_list}] = taken
      assert await_records() == []
    end

    test "disconnect clears pending records; the callback does not fire" do
      doc = new_document("<div id='p'></div>")
      p = DOM.query_selector(doc, "#p")
      mo = observer(doc)
      MutationObserver.observe(mo, p, child_list: true)

      DOM.lambda(doc.server, fn ->
        Node.append_child(p, DOM.create_element(doc, "a"))
        MutationObserver.disconnect(mo)
      end)

      assert await_records() == []
    end
  end
end
