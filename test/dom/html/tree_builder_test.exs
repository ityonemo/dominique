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

  # Parse `html` as the contents of a `context` element (fragment parsing) and
  # render the fragment outline (the synthetic root's children).
  defp fragment(html, context) do
    html |> DOM.HTML.parse_fragment(context) |> DatOutline.serialize_fragment()
  end

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

    # spec §13.2.6.4.7: "An end tag whose tag name is br" — act as if a <br>
    # START tag had been seen (a void <br> element is inserted).
    test "</br> is treated as a <br> start tag" do
      assert tree("a</br>b") == doc(["|     \"a\"", "|     <br>", "|     \"b\""])
    end
  end

  describe "after head — §13.2.6.4.6" do
    # spec §13.2.6.4.6: a head-element start tag after </head> re-enters the head
    # (push head, process in-head, pop head) — so <base> lands in <head>, not body.
    test "a base start tag after </head> goes back into head" do
      assert tree("</head><base>X") ==
               "| <html>\n|   <head>\n|     <base>\n|   <body>\n|     \"X\""
    end

    # spec §13.2.6.4.6: likewise a <title> after </head> is parsed as head RCDATA.
    test "a title after </head> goes back into head" do
      assert tree("<head></head><title>X</title>") ==
               "| <html>\n|   <head>\n|     <title>\n|       \"X\"\n|   <body>"
    end
  end

  describe "in head noscript — §13.2.6.4.5 (scripting disabled)" do
    # spec §13.2.6.4.5: with scripting disabled, <noscript> in head opens the
    # "in head noscript" mode; a disallowed start tag (e.g. iframe) pops the
    # noscript and is reprocessed — landing in the body. (iframe is rawtext, so
    # its interior `</noscript>X` is text.)
    test "an iframe inside head noscript pops out to the body" do
      assert tree("<noscript><iframe></noscript>X") ==
               "| <html>\n|   <head>\n|     <noscript>\n|   <body>\n" <>
                 "|     <iframe>\n|       \"</noscript>X\""
    end

    # spec §13.2.6.4.5: a metadata element (link) inside head noscript stays in
    # head via the "in head" delegation.
    test "a link inside head noscript stays in head" do
      assert tree("<noscript><link></noscript>") ==
               "| <html>\n|   <head>\n|     <noscript>\n|       <link>\n|   <body>"
    end
  end

  describe "in body — §13.2.6.4.7 the table start tag" do
    # spec §13.2.6.4.7: "A start tag whose tag name is table" — close a p in
    # button scope, insert, switch to "in table".
    test "a table start tag closes an open p and switches to in table" do
      assert tree("<p>a<table>") ==
               doc(["|     <p>", "|       \"a\"", "|     <table>"])
    end

    # spec §13.2.6.4.7 (</form> end tag): the form pointer is checked against the
    # stack. A form fostered out of the stack by a table leaves a dangling
    # pointer, and </form> must ignore it (not crash). Regression guard.
    test "a form fostered by a table does not crash on </form>" do
      assert tree("<form><table></form>x</table>") ==
               doc([
                 "|     <form>",
                 "|       \"x\"",
                 "|       <table>"
               ])
    end
  end

  describe "in table — §13.2.6.4.9" do
    # spec §13.2.6.4.9: "A start tag whose tag name is caption" — clear to a
    # table context, insert, switch to "in caption".
    test "a caption start tag is inserted into the table" do
      assert tree("<table><caption>x") ==
               doc(["|     <table>", "|       <caption>", "|         \"x\""])
    end

    # spec §13.2.6.4.9: "A start tag whose tag name is colgroup" — clear to a
    # table context, insert, switch to "in column group".
    test "a colgroup start tag is inserted into the table" do
      assert tree("<table><colgroup>") ==
               doc(["|     <table>", "|       <colgroup>"])
    end

    # spec §13.2.6.4.9: "A start tag whose tag name is col" — insert an implied
    # colgroup, then reprocess col in "in column group".
    test "a bare col implies a colgroup" do
      assert tree("<table><col>") ==
               doc(["|     <table>", "|       <colgroup>", "|         <col>"])
    end

    # spec §13.2.6.4.9: "A start tag whose tag name is one of tbody/tfoot/thead"
    # — clear to a table context, insert, switch to "in table body".
    test "a tbody start tag is inserted into the table" do
      assert tree("<table><tbody>") ==
               doc(["|     <table>", "|       <tbody>"])
    end

    # spec §13.2.6.4.9: "A start tag whose tag name is one of td/th/tr" — insert
    # an implied tbody, then reprocess in "in table body".
    test "a bare tr implies a tbody" do
      assert tree("<table><tr>") ==
               doc(["|     <table>", "|       <tbody>", "|         <tr>"])
    end

    # spec §13.2.6.4.9: "A start tag whose tag name is table" — pop through the
    # open table and reprocess (so a nested table start closes the outer table).
    test "a nested table start tag closes the outer table" do
      assert tree("<table><table>") ==
               doc(["|     <table>", "|     <table>"])
    end

    # spec §13.2.6.4.9: "An end tag whose tag name is table" — pop through the
    # table and reset the insertion mode.
    test "an end tag table closes the table" do
      assert tree("<table></table>a") ==
               doc(["|     <table>", "|     \"a\""])
    end

    # spec §13.2.6.4.9 (anything else): foster parenting — misnested content in a
    # table is inserted before the table.
    test "misnested content is foster-parented before the table" do
      assert tree("<table><b>x</table>") ==
               doc(["|     <b>", "|       \"x\"", "|     <table>"])
    end
  end

  describe "in table text — §13.2.6.4.10" do
    # spec §13.2.6.4.10: whitespace-only pending characters are inserted (into the
    # table), not foster-parented.
    test "whitespace between table and row stays inside the table" do
      assert tree("<table> <tbody>") ==
               doc(["|     <table>", "|       \" \"", "|       <tbody>"])
    end

    # spec §13.2.6.4.10: pending characters containing non-whitespace are a parse
    # error and foster-parented before the table.
    test "non-whitespace table text is foster-parented before the table" do
      assert tree("<table>x<tbody>") ==
               doc(["|     \"x\"", "|     <table>", "|       <tbody>"])
    end
  end

  describe "in caption — §13.2.6.4.11" do
    # spec §13.2.6.4.11: "An end tag whose tag name is caption" — pop through the
    # caption and switch back to "in table".
    test "an end caption returns to in table" do
      assert tree("<table><caption>x</caption><tbody>") ==
               doc([
                 "|     <table>",
                 "|       <caption>",
                 "|         \"x\"",
                 "|       <tbody>"
               ])
    end

    # spec §13.2.6.4.11: a table-child start tag closes the caption and is
    # reprocessed in "in table".
    test "a tbody start tag inside a caption closes the caption" do
      assert tree("<table><caption>x<tbody>") ==
               doc([
                 "|     <table>",
                 "|       <caption>",
                 "|         \"x\"",
                 "|       <tbody>"
               ])
    end
  end

  describe "in column group — §13.2.6.4.12" do
    # spec §13.2.6.4.12: "A start tag whose tag name is col" — insert, immediately
    # pop (void).
    test "a col inside a colgroup is a void child" do
      assert tree("<table><colgroup><col>") ==
               doc(["|     <table>", "|       <colgroup>", "|         <col>"])
    end

    # spec §13.2.6.4.12: "An end tag whose tag name is colgroup" — pop the
    # colgroup, switch to "in table".
    test "an end colgroup returns to in table" do
      assert tree("<table><colgroup></colgroup><tbody>") ==
               doc(["|     <table>", "|       <colgroup>", "|       <tbody>"])
    end

    # spec §13.2.6.4.12 (anything else): a non-col token pops the colgroup and is
    # reprocessed in "in table".
    test "a tbody after a colgroup pops the colgroup" do
      assert tree("<table><colgroup><tbody>") ==
               doc(["|     <table>", "|       <colgroup>", "|       <tbody>"])
    end
  end

  describe "in table body — §13.2.6.4.13" do
    # spec §13.2.6.4.13: "A start tag whose tag name is tr" — clear to a table
    # body context, insert, switch to "in row".
    test "a tr start tag is inserted into the tbody" do
      assert tree("<table><tbody><tr>") ==
               doc(["|     <table>", "|       <tbody>", "|         <tr>"])
    end

    # spec §13.2.6.4.13: "A start tag whose tag name is one of th/td" — insert an
    # implied tr, then reprocess in "in row".
    test "a bare td inside a tbody implies a tr" do
      assert tree("<table><tbody><td>x") ==
               doc([
                 "|     <table>",
                 "|       <tbody>",
                 "|         <tr>",
                 "|           <td>",
                 "|             \"x\""
               ])
    end

    # spec §13.2.6.4.13: "An end tag whose tag name is one of tbody/tfoot/thead" —
    # pop the section, switch to "in table".
    test "an end tbody returns to in table" do
      assert tree("<table><tbody></tbody><tfoot>") ==
               doc(["|     <table>", "|       <tbody>", "|       <tfoot>"])
    end
  end

  describe "in row — §13.2.6.4.14" do
    # spec §13.2.6.4.14: "A start tag whose tag name is one of th/td" — clear to a
    # table row context, insert, switch to "in cell".
    test "a td start tag is inserted into the tr" do
      assert tree("<table><tr><td>x") ==
               doc([
                 "|     <table>",
                 "|       <tbody>",
                 "|         <tr>",
                 "|           <td>",
                 "|             \"x\""
               ])
    end

    # spec §13.2.6.4.14: "An end tag whose tag name is tr" — pop the tr, switch to
    # "in table body".
    test "an end tr returns to in table body" do
      assert tree("<table><tr></tr><tr>") ==
               doc([
                 "|     <table>",
                 "|       <tbody>",
                 "|         <tr>",
                 "|         <tr>"
               ])
    end

    # spec §13.2.6.4.14: a new tr closes the current one (via the table-child
    # reprocess path).
    test "a second tr closes the first" do
      assert tree("<table><tr><td>a<tr><td>b") ==
               doc([
                 "|     <table>",
                 "|       <tbody>",
                 "|         <tr>",
                 "|           <td>",
                 "|             \"a\"",
                 "|         <tr>",
                 "|           <td>",
                 "|             \"b\""
               ])
    end
  end

  describe "in cell — §13.2.6.4.15" do
    # spec §13.2.6.4.15: "An end tag whose tag name is one of td/th" — generate
    # implied end tags, pop through the cell, switch to "in row".
    test "an end td returns to in row" do
      assert tree("<table><tr><td>a</td><td>b") ==
               doc([
                 "|     <table>",
                 "|       <tbody>",
                 "|         <tr>",
                 "|           <td>",
                 "|             \"a\"",
                 "|           <td>",
                 "|             \"b\""
               ])
    end

    # spec §13.2.6.4.15: a new cell start tag closes the open cell (close-the-cell
    # then reprocess).
    test "a second td closes the first" do
      assert tree("<table><tr><td>a<td>b") ==
               doc([
                 "|     <table>",
                 "|       <tbody>",
                 "|         <tr>",
                 "|           <td>",
                 "|             \"a\"",
                 "|           <td>",
                 "|             \"b\""
               ])
    end

    # spec §13.2.6.4.15 (anything else): ordinary content inside a cell is
    # processed as "in body".
    test "ordinary content inside a cell is inserted normally" do
      assert tree("<table><tr><td><p>x") ==
               doc([
                 "|     <table>",
                 "|       <tbody>",
                 "|         <tr>",
                 "|           <td>",
                 "|             <p>",
                 "|               \"x\""
               ])
    end
  end

  describe "in body — §13.2.4.3 active formatting list (reconstruction)" do
    # spec §13.2.4.3: reconstruct the active formatting elements — the </b>
    # adoption splits <b> out of the <p>; the "2" inside the <p> is wrapped by a
    # reconstructed <b>, and "3" (after </b>) stays bare in the <p>.
    test "a formatting element is reconstructed inside an adopted block" do
      assert tree("<b>1<p>2</b>3</p>") ==
               doc([
                 "|     <b>",
                 "|       \"1\"",
                 "|     <p>",
                 "|       <b>",
                 "|         \"2\"",
                 "|       \"3\""
               ])
    end

    # spec §13.2.4.3 (Noah's Ark): four identical <b> nest fully inside the first
    # <p>, but after the second <p> reconstruction rebuilds only three of them
    # (the earliest equal entry was dropped when the fourth was pushed).
    test "Noah's Ark caps reconstruction at three equal formatting entries" do
      assert tree("<p><b><b><b><b><p>x") ==
               doc([
                 "|     <p>",
                 "|       <b>",
                 "|         <b>",
                 "|           <b>",
                 "|             <b>",
                 "|     <p>",
                 "|       <b>",
                 "|         <b>",
                 "|           <b>",
                 "|             \"x\""
               ])
    end
  end

  describe "in body — §13.2.6.4.7 adoption agency" do
    # spec §13.2.6.4.7: "An end tag whose tag name is one of: a, b, …" runs the
    # adoption agency — misnested <b>/<i> split so the <i> continues after </b>.
    test "misnested b/i are repaired by the adoption agency" do
      assert tree("<b>1<i>2</b>3</i>") ==
               doc([
                 "|     <b>",
                 "|       \"1\"",
                 "|       <i>",
                 "|         \"2\"",
                 "|     <i>",
                 "|       \"3\""
               ])
    end

    # spec §13.2.6.4.7 (<a> start tag): an <a> while an <a> is open runs the
    # adoption agency on the open one first, so the two <a>s are siblings.
    test "a nested a start tag closes the open a via the adoption agency" do
      assert tree("<a>1<a>2") ==
               doc(["|     <a>", "|       \"1\"", "|     <a>", "|       \"2\""])
    end

    # spec §13.2.6.4.7: the adoption agency moves the furthest block's contents —
    # a formatting element wrapping a block is repaired around it.
    test "a formatting element around a block is repaired" do
      assert tree("<b>1<p>2</b>3") ==
               doc([
                 "|     <b>",
                 "|       \"1\"",
                 "|     <p>",
                 "|       <b>",
                 "|         \"2\"",
                 "|       \"3\""
               ])
    end
  end

  describe "foreign content — §13.2.6.4.7 / §13.2.6.5 (SVG / MathML)" do
    # spec §13.2.6.4.7 (<svg> start tag): insert a foreign element in the SVG
    # namespace; its children are also SVG (outline shows the `svg ` prefix).
    test "an svg element and its children are in the SVG namespace" do
      assert tree("<svg><circle></svg>") ==
               doc(["|     <svg svg>", "|       <svg circle>"])
    end

    # spec §13.2.6.4.7 (<math> start tag): insert a foreign element in the MathML
    # namespace.
    test "a math element and its children are in the MathML namespace" do
      assert tree("<math><mi>x</mi></math>") ==
               doc(["|     <math math>", "|       <math mi>", "|         \"x\""])
    end

    # spec §13.2.6.5 (any other start tag, SVG tag fixup): a lowercased SVG tag
    # name is corrected to its canonical camelCase form.
    test "an SVG tag name is case-corrected" do
      assert tree("<svg><clippath></svg>") ==
               doc(["|     <svg svg>", "|       <svg clipPath>"])
    end

    # spec §13.2.6.5 (adjust foreign attributes): a prefixed foreign attribute is
    # rendered as two columns (`xlink href`).
    test "a foreign xlink attribute is namespaced" do
      assert tree("<svg xlink:href=foo></svg>") ==
               doc(["|     <svg svg>", "|       xlink href=\"foo\""])
    end

    # spec §13.2.6.5 (adjust SVG attributes): a lowercased SVG attribute name is
    # case-corrected.
    test "an SVG attribute name is case-corrected" do
      assert tree("<svg viewbox=\"0\"></svg>") ==
               doc(["|     <svg svg>", "|       viewBox=\"0\""])
    end

    # spec §13.2.6 (HTML integration point): inside SVG foreignObject, HTML
    # content resumes — a div is an HTML-namespace element.
    test "content inside foreignObject is HTML" do
      assert tree("<svg><foreignObject><div>x</div></foreignObject></svg>") ==
               doc([
                 "|     <svg svg>",
                 "|       <svg foreignObject>",
                 "|         <div>",
                 "|           \"x\""
               ])
    end

    # spec §13.2.6 (MathML text integration point): inside mtext, HTML content
    # resumes.
    test "content inside an mtext integration point is HTML" do
      assert tree("<math><mtext><b>x</b></mtext></math>") ==
               doc([
                 "|     <math math>",
                 "|       <math mtext>",
                 "|         <b>",
                 "|           \"x\""
               ])
    end

    # spec §13.2.6.5 (breakout start tag): an HTML block start tag inside foreign
    # content pops back out to HTML content.
    test "a breakout start tag exits foreign content" do
      assert tree("<svg><circle><p>x") ==
               doc([
                 "|     <svg svg>",
                 "|       <svg circle>",
                 "|     <p>",
                 "|       \"x\""
               ])
    end
  end

  describe "fragment parsing — §13.4" do
    # spec §13.4: fragment children are returned without the html/head/body
    # wrapper — a div context yields the content directly.
    test "a div-context fragment has no html/body wrapper" do
      assert fragment("<span>x</span>", "div") ==
               "| <span>\n|   \"x\""
    end

    # A head-context fragment does not imply html/head/body at EOF (the synthetic
    # root is fixed) — regression guard for a HierarchyRequestError crash.
    test "a head-context fragment does not imply a body at EOF" do
      assert fragment("<title>x</title>", "head") == ~s(| <title>\n|   "x")
    end

    # spec §13.4 (tokenizer state for RCDATA context): a textarea context treats
    # its input as raw text — markup is not parsed.
    test "a textarea context treats markup as raw text" do
      assert fragment("a<b>c", "textarea") == "| \"a<b>c\""
    end

    # spec §13.2.6.3 (reset the insertion mode, fragment case): a tr context
    # starts in the "in row" mode, so a bare <td> is inserted directly.
    test "a tr context places a bare td directly" do
      assert fragment("<td>x", "tr") ==
               "| <td>\n|   \"x\""
    end

    # spec §13.2.6.3 (reset, fragment case): a table context starts "in table",
    # so a bare <tr> implies a tbody.
    test "a table context implies a tbody around a bare tr" do
      assert fragment("<tr><td>x", "table") ==
               "| <tbody>\n|   <tr>\n|     <td>\n|       \"x\""
    end

    # spec §13.4 (foreign context): an SVG context parses its children in the SVG
    # namespace.
    test "an svg context parses children in the SVG namespace" do
      assert fragment("<circle>", "svg path") == "| <svg circle>"
    end

    # spec §13.2.6.4.7 (<body> start tag): a body start tag in a body-context
    # fragment is ignored (no element created).
    test "a body start tag is ignored in a body-context fragment" do
      assert fragment("<body><span>", "body") == "| <span>"
    end
  end

  describe "in select — §13.2.6.4.16" do
    # spec §13.2.6.4.16: option/optgroup are inserted; consecutive options do not
    # nest (a second option pops the first).
    test "options do not nest inside a select" do
      assert tree("<select><option>a<option>b") ==
               doc([
                 "|     <select>",
                 "|       <option>",
                 "|         \"a\"",
                 "|       <option>",
                 "|         \"b\""
               ])
    end

    # Customizable select: arbitrary content (button/div/datalist) nests inside a
    # select via the "in body" fallback (not ignored).
    test "customizable-select content nests inside the select" do
      assert tree("<select><button>b</button><div>d</div><datalist><option>o") ==
               doc([
                 "|     <select>",
                 "|       <button>",
                 "|         \"b\"",
                 "|       <div>",
                 "|         \"d\"",
                 "|       <datalist>",
                 "|         <option>",
                 "|           \"o\""
               ])
    end

    # spec §13.2.6.4.16 (<hr> start tag): an hr pops a current option/optgroup and
    # is inserted as a void child of the select.
    test "an hr in a select is a void child" do
      assert tree("<select><option>a<hr>") ==
               doc([
                 "|     <select>",
                 "|       <option>",
                 "|         \"a\"",
                 "|       <hr>"
               ])
    end

    # spec §13.2.6.4.16 (</select> end tag): closes the select and returns to the
    # enclosing mode.
    test "an end select closes the select" do
      assert tree("<select><option>a</select>b") ==
               doc([
                 "|     <select>",
                 "|       <option>",
                 "|         \"a\"",
                 "|     \"b\""
               ])
    end

    # spec §13.2.6.4.16 (<select> start tag): a nested select start tag closes the
    # open select (acts like </select>).
    test "a nested select start tag closes the open select" do
      assert tree("<select><select>a") ==
               doc(["|     <select>", "|     \"a\""])
    end
  end

  describe "in frameset — §13.2.6.4.18" do
    # spec §13.2.6.4.18: a frameset holds frame (void) children.
    test "a frameset holds frame children" do
      assert tree("<frameset><frame></frameset>") ==
               "| <html>\n|   <head>\n|   <frameset>\n|     <frame>"
    end

    # spec §13.2.6.4.7 (<frameset> in body): a frameset immediately after an empty
    # body replaces it (frameset-ok still set).
    test "a frameset replaces an empty body" do
      assert tree("<frameset><frame>") ==
               "| <html>\n|   <head>\n|   <frameset>\n|     <frame>"
    end

    # spec §13.2.6.4.7: once non-whitespace content sets frameset-ok to not ok, a
    # later frameset is ignored.
    test "a frameset after body content is ignored" do
      assert tree("<body>x<frameset><frame>") ==
               "| <html>\n|   <head>\n|   <body>\n|     \"x\""
    end

    # spec §13.2.6.4.19 (after frameset </html>): the trailing html end tag
    # switches to "after after frameset"; a following comment lands on the
    # document.
    test "a comment after </html> in a frameset document lands on the document" do
      assert tree("<frameset></frameset></html><!--x-->") ==
               "| <html>\n|   <head>\n|   <frameset>\n| <!-- x -->"
    end
  end

  describe "in template — §13.2.6.4.16" do
    # spec §13.2.6.4.16: template contents go into the template's content
    # DocumentFragment, rendered as a `content` pseudo-node.
    test "template contents live in a content fragment" do
      assert tree("<body><template>Hello</template>") ==
               doc([
                 "|     <template>",
                 "|       content",
                 "|         \"Hello\""
               ])
    end

    # spec §13.2.6.4.16 (table-content start tags): a <tr> inside a template
    # switches the template mode to "in table body" and inserts the row directly.
    # (A body is implied at EOF since the document had no body.)
    test "a tr in a template is placed in its content" do
      assert tree("<template><tr><td>x") ==
               Enum.join(
                 [
                   "| <html>",
                   "|   <head>",
                   "|     <template>",
                   "|       content",
                   "|         <tr>",
                   "|           <td>",
                   "|             \"x\"",
                   "|   <body>"
                 ],
                 "\n"
               )
    end

    # spec §13.2.6.4.16 (any other start tag): a plain element in a template goes
    # into its content via "in body".
    test "a plain element in a template goes into its content" do
      assert tree("<body><template><div>x</div></template>") ==
               doc([
                 "|     <template>",
                 "|       content",
                 "|         <div>",
                 "|           \"x\""
               ])
    end

    # spec §13.2.6.4.16 (</template> end tag): closing a template returns to the
    # enclosing insertion mode, so following content is a sibling of the template.
    test "content after a closed template is a sibling" do
      assert tree("<body><template>a</template>b") ==
               doc([
                 "|     <template>",
                 "|       content",
                 "|         \"a\"",
                 "|     \"b\""
               ])
    end

    # spec §13.2.6.4.16: nested templates each get their own content fragment.
    test "nested templates nest their content fragments" do
      assert tree("<body><template><template>x</template></template>") ==
               doc([
                 "|     <template>",
                 "|       content",
                 "|         <template>",
                 "|           content",
                 "|             \"x\""
               ])
    end
  end

  describe "in body — §13.2.6.4.7 ruby / plaintext" do
    # spec §13.2.6.4.7: a start tag "rp"/"rt" — if a ruby is in scope, generate
    # implied end tags (except rtc). So an open <p> inside <ruby> closes before
    # the <rp>, making them siblings.
    test "an rp start tag closes an implied-open p inside a ruby" do
      assert tree("<ruby><p><rp>") ==
               doc(["|     <ruby>", "|       <p>", "|       <rp>"])
    end

    # spec §13.2.6.4.7: a start tag "rb" — if a ruby is in scope, generate implied
    # end tags; a preceding rp/rt closes.
    test "an rb start tag closes a preceding rt" do
      assert tree("<ruby><rt>a<rb>b") ==
               doc([
                 "|     <ruby>",
                 "|       <rt>",
                 "|         \"a\"",
                 "|       <rb>",
                 "|         \"b\""
               ])
    end

    # spec §13.2.6.4.7: a start tag "plaintext" closes a p in button scope and is
    # inserted as a sibling; the rest of input is its raw text.
    test "a plaintext start tag closes an open p" do
      assert tree("<p>a<plaintext>b</p>c") ==
               doc([
                 "|     <p>",
                 "|       \"a\"",
                 "|     <plaintext>",
                 "|       \"b</p>c\""
               ])
    end

    # spec §13.2.6.4.7: textarea/xmp/iframe are in-body-only rawtext elements —
    # they must imply a <body> (not land in <head>) when they open the document.
    test "a leading textarea implies a body (not head)" do
      assert tree("<textarea>x</textarea>") ==
               doc(["|     <textarea>", "|       \"x\""])
    end
  end

  describe "foreign content — §13.2.6.5 attribute case fixups" do
    # spec §13.2.6.5 (adjust MathML attributes): a nested MathML element's
    # definitionurl attribute is case-corrected to definitionURL.
    test "definitionurl is corrected on a nested MathML element" do
      assert tree(~s(<math><mn definitionurl="foo">)) ==
               doc([
                 "|     <math math>",
                 "|       <math mn>",
                 "|         definitionURL=\"foo\""
               ])
    end

    # spec §13.2.6.5 (adjust SVG attributes): a nested SVG element's attribute
    # name is case-corrected (e.g. gradientunits -> gradientUnits).
    test "an SVG attribute name is corrected on a nested SVG element" do
      assert tree(~s(<svg><lineargradient gradientunits="x">)) ==
               doc([
                 "|     <svg svg>",
                 "|       <svg linearGradient>",
                 "|         gradientUnits=\"x\""
               ])
    end
  end

  describe "DOCTYPE public/system identifiers (§13.2.6.4.1 + serialization)" do
    # A doctype with no ids renders bare.
    test "a bare doctype renders without ids" do
      assert tree("<!DOCTYPE html>") |> String.starts_with?("| <!DOCTYPE html>\n")
    end

    # PUBLIC + SYSTEM ids are preserved and serialized.
    test "public and system identifiers are preserved" do
      out = tree(~s(<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://x">))

      assert String.starts_with?(
               out,
               ~s(| <!DOCTYPE html "-//W3C//DTD HTML 4.01//EN" "http://x">\n)
             )
    end

    # A SYSTEM-only doctype renders the public id as "".
    test "a system-only doctype renders an empty public id" do
      out = tree("<!DOCTYPE potato SYSTEM 'taco'>")
      assert String.starts_with?(out, ~s(| <!DOCTYPE potato "" "taco">\n))
    end
  end

  describe "in body — §13.2.6.4.7 duplicate html/body attribute merging" do
    # spec §13.2.6.4.7: a duplicate <html> start tag merges any attribute not
    # already present onto the existing html element.
    test "a duplicate html start tag merges new attributes" do
      out = tree("<html a=b><head></head><html c=d>")
      assert out =~ ~s(| <html>\n|   a="b"\n|   c="d"\n)
    end

    # spec §13.2.6.4.7: a duplicate <body> start tag merges onto the existing body.
    test "a duplicate body start tag merges new attributes" do
      assert tree("<body t1=1><body t2=2>") =~ ~s(|   <body>\n|     t1="1"\n|     t2="2")
    end
  end
end
