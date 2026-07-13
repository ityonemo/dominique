defmodule DOM.TargetTest do
  use DOM.Case, async: true

  # :target matches the "indicated part of the document" — the element whose id equals
  # the document fragment (case-sensitive), or an <a name=…> when no id matches (id
  # wins when both exist). Dominique has no URL, so DOM.set_fragment/2 sets it.
  # Browser-verified in the target-hover-active-semantics memory.

  test "no fragment: nothing matches :target" do
    doc = new_document("<body><div id='sec'></div></body>")
    refute DOM.matches(DOM.query_selector(doc, "#sec"), ":target")
  end

  test "set_fragment makes the id-matching element :target" do
    doc = new_document("<body><div id='a'></div><div id='b'></div></body>")
    DOM.set_fragment(doc, "a")

    assert DOM.matches(DOM.query_selector(doc, "#a"), ":target")
    refute DOM.matches(DOM.query_selector(doc, "#b"), ":target")
  end

  test "changing the fragment moves :target" do
    doc = new_document("<body><div id='a'></div><div id='b'></div></body>")
    DOM.set_fragment(doc, "a")
    DOM.set_fragment(doc, "b")

    refute DOM.matches(DOM.query_selector(doc, "#a"), ":target")
    assert DOM.matches(DOM.query_selector(doc, "#b"), ":target")
  end

  test "clearing the fragment (nil) unmatches :target" do
    doc = new_document("<body><div id='a'></div></body>")
    DOM.set_fragment(doc, "a")
    DOM.set_fragment(doc, nil)
    refute DOM.matches(DOM.query_selector(doc, "#a"), ":target")
  end

  test "a nonexistent fragment matches nothing" do
    doc = new_document("<body><div id='a'></div></body>")
    DOM.set_fragment(doc, "missing")
    refute DOM.matches(DOM.query_selector(doc, "#a"), ":target")
  end

  test ":target is case-sensitive" do
    doc = new_document("<body><div id='X'></div></body>")
    DOM.set_fragment(doc, "x")
    refute DOM.matches(DOM.query_selector(doc, "#X"), ":target")
  end

  test "an <a name=…> matches :target when no id matches" do
    doc = new_document("<body><a name='anchor'>a</a></body>")
    DOM.set_fragment(doc, "anchor")
    assert DOM.matches(DOM.query_selector(doc, "a"), ":target")
  end

  test "id wins over a[name] for the same fragment" do
    doc = new_document("<body><div id='x'></div><a name='x'>a</a></body>")
    DOM.set_fragment(doc, "x")

    assert DOM.matches(DOM.query_selector(doc, "#x"), ":target")
    refute DOM.matches(DOM.query_selector(doc, "a"), ":target")
  end
end
