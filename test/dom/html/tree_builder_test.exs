defmodule DOM.HTML.TreeBuilderTest do
  use ExUnit.Case, async: true

  # Per-rule unit tests for the tree builder (DOM.HTML.TreeBuilder), one test per
  # spec text item, each citing the WHATWG rule it exercises. Grouped by
  # insertion mode. Assertions compare the parsed tree, rendered via DatOutline
  # (the same #document outline the data-driven suite uses), against the expected
  # structure — so the test reads as "this input yields this tree".
  #
  # Spec: https://html.spec.whatwg.org/multipage/parsing.html#tree-construction
  #
  # The data-driven html5lib suite (tree_builder_automate_test.exs) is the broad
  # conformance net; these are the focused, spec-cited invariants.

  # Parse `html` and render its document tree as the .dat #document outline.
  defp tree(html), do: html |> DOM.HTML.parse() |> DatOutline.serialize()

  # A well-formed <html><head></head><body>…</body></html> outline whose body
  # contains `body_lines` (already "| "-prefixed and indented to body depth).
  defp doc(body_lines) do
    ["| <html>", "|   <head>", "|   <body>" | body_lines] |> Enum.join("\n")
  end

  describe "in body — §13.2.6.4.7 start tags that close a p element in button scope" do
    # spec §13.2.6.4.7: "A start tag whose tag name is one of: address, article,
    # …, div, dl, …, p, section, …" — if a p element is in button scope, close it.
    test "a block-level start tag closes an open p" do
      assert tree("<p>a<div>b") ==
               doc(["|     <p>", "|       \"a\"", "|     <div>", "|       \"b\""])
    end

    # spec §13.2.6.4.7: same rule — nested block elements each close the prior p.
    test "a second p start tag closes the first p" do
      assert tree("<p>a<p>b") ==
               doc(["|     <p>", "|       \"a\"", "|     <p>", "|       \"b\""])
    end

    # spec §13.2.6.4.7: "A start tag whose tag name is one of: h1, h2, h3, h4,
    # h5, h6" — close a p in button scope, then insert.
    test "a heading start tag closes an open p" do
      assert tree("<p>a<h1>b") ==
               doc(["|     <p>", "|       \"a\"", "|     <h1>", "|       \"b\""])
    end

    # spec §13.2.6.4.7: "if the current node is an HTML element whose tag name is
    # one of h1..h6" pop it — consecutive headings do not nest.
    test "a heading start tag pops a current heading (headings do not nest)" do
      assert tree("<h1>a<h2>b") ==
               doc(["|     <h1>", "|       \"a\"", "|     <h2>", "|       \"b\""])
    end

    # spec §13.2.6.4.7: "A start tag whose tag name is hr" — close a p in button
    # scope, insert, immediately pop (void).
    test "an hr start tag closes an open p and is a sibling" do
      assert tree("<p>a<hr>") ==
               doc(["|     <p>", "|       \"a\"", "|     <hr>"])
    end

    # spec §13.2.6.4.7: "A start tag whose tag name is image" — act as if it were
    # img (a parse error).
    test "an image start tag is treated as img" do
      assert tree("<image>") == doc(["|     <img>"])
    end
  end

  describe "in body — §13.2.6.4.7 li/dd/dt auto-closing" do
    # spec §13.2.6.4.7: "A start tag whose tag name is li" — loop up the stack;
    # an open li is closed before the new one is inserted (siblings).
    test "a second li closes the first" do
      assert tree("<li>a<li>b") ==
               doc(["|     <li>", "|       \"a\"", "|     <li>", "|       \"b\""])
    end

    # spec §13.2.6.4.7: the li loop stops at a special element that is not
    # address/div/p — so a ul between two li keeps the inner li nested.
    test "an li inside a nested ul nests, not closing the outer li" do
      assert tree("<li>a<ul>b<li>c") ==
               doc([
                 "|     <li>",
                 "|       \"a\"",
                 "|       <ul>",
                 "|         \"b\"",
                 "|         <li>",
                 "|           \"c\""
               ])
    end

    # spec §13.2.6.4.7: "A start tag whose tag name is dd or dt" — dt then dd are
    # siblings (dd closes the open dt).
    test "a dd start tag closes an open dt" do
      assert tree("<dt>a<dd>b") ==
               doc(["|     <dt>", "|       \"a\"", "|     <dd>", "|       \"b\""])
    end

    # spec §13.2.6.4.7: the dd/dt loop walks past address/div/p — an intervening
    # div does not stop dd from closing dt.
    test "a dd start tag closes dt through an intervening div" do
      assert tree("<dt><div><dd>") ==
               doc(["|     <dt>", "|       <div>", "|     <dd>"])
    end
  end

  describe "in body — §13.2.6.4.7 end tags with implied end tags + scope" do
    # spec §13.2.6.4.7: "An end tag whose tag name is p" — if no p is in button
    # scope, a p is inserted then immediately closed; inside a div (so we are in
    # body) a stray </p> yields an empty p.
    test "a stray </p> in body creates and closes an empty p" do
      assert tree("<div></p>") == doc(["|     <div>", "|       <p>"])
    end

    # spec §13.2.6.4.7: "An end tag whose tag name is li" — generate implied end
    # tags except li, then pop through the li; an open p inside closes.
    test "</li> closes an implied-open p inside the li" do
      assert tree("<li><p>a</li>b") ==
               doc([
                 "|     <li>",
                 "|       <p>",
                 "|         \"a\"",
                 "|     \"b\""
               ])
    end

    # spec §13.2.6.4.7: "An end tag whose tag name is one of: address, …, div,
    # …" — if in scope, generate implied end tags then pop through it.
    test "</div> closes an implied-open p inside the div" do
      assert tree("<div><p>a</div>b") ==
               doc([
                 "|     <div>",
                 "|       <p>",
                 "|         \"a\"",
                 "|     \"b\""
               ])
    end

    # spec §13.2.6.4.7: "An end tag whose tag name is one of: h1..h6" — pop
    # through the first heading on the stack even if the names differ.
    test "</h2> closes an open h1 (any heading matches)" do
      assert tree("<h1>a</h2>b") ==
               doc(["|     <h1>", "|       \"a\"", "|     \"b\""])
    end

    # spec §13.2.6.4.7: an end tag not in scope is a parse error and ignored —
    # the surrounding text is unaffected (and coalesces into one Text node).
    test "an end tag whose element is not in scope is ignored" do
      assert tree("<div>a</span>b") ==
               doc(["|     <div>", "|       \"ab\""])
    end

    # spec §13.2.6.4.7: "Any other end tag" — walk the stack; a matching
    # non-special element closes normally.
    test "any-other end tag closes its matching element" do
      assert tree("<b>a</b>b") ==
               doc(["|     <b>", "|       \"a\"", "|     \"b\""])
    end
  end
end
