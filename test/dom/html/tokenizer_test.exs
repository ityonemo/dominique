defmodule DOM.HTML.TokenizerTest do
  use ExUnit.Case, async: true

  alias DOM.HTML.Token

  defp tokenize(html), do: DOM.HTML.tokenize(html)

  # The single Character run captured as a <script> element's interior. Assumes
  # the input opens with `<script>`; returns "" when the interior is empty.
  defp script_interior(html) do
    case tokenize(html) do
      [%Token.StartTag{name: "script"}, %Token.Character{data: data} | _] -> data
      [%Token.StartTag{name: "script"} | _] -> ""
    end
  end

  describe "tags" do
    test "a single start tag" do
      assert tokenize("<h>") == [%Token.StartTag{name: "h", attributes: [], self_closing: false}]
    end

    test "an end tag" do
      assert tokenize("</h>") == [%Token.EndTag{name: "h"}]
    end

    test "lowercases the tag name" do
      assert [%Token.StartTag{name: "div"}] = tokenize("<DIV>")
    end

    test "a self-closing start tag" do
      assert [%Token.StartTag{name: "br", self_closing: true}] = tokenize("<br/>")
    end

    # WHATWG before-attribute-name: a `/` that does not form `/>` is an attribute
    # separator, not the self-closing marker.
    test "a stray / inside a tag separates attributes" do
      assert [%Token.StartTag{name: "p", attributes: [{"x", ""}, {"y", ""}], self_closing: false}] =
               tokenize("<p/x/y>")
    end

    # An end tag may carry attributes (which are dropped).
    test "an end tag with attributes drops them" do
      assert [%Token.EndTag{name: "b"}] = tokenize("</b test>")
    end
  end

  describe "attributes" do
    test "a double-quoted attribute" do
      assert [%Token.StartTag{name: "a", attributes: [{"href", "/x"}]}] =
               tokenize(~s(<a href="/x">))
    end

    test "a single-quoted attribute" do
      assert [%Token.StartTag{attributes: [{"a", "b"}]}] = tokenize("<h a='b'>")
    end

    test "an unquoted attribute" do
      assert [%Token.StartTag{attributes: [{"a", "b"}]}] = tokenize("<h a=b>")
    end

    test "a valueless attribute" do
      assert [%Token.StartTag{attributes: [{"a", ""}]}] = tokenize("<h a>")
    end

    test "lowercases attribute names, in order" do
      assert [%Token.StartTag{attributes: [{"a", ""}, {"b", ""}]}] = tokenize("<h a B>")
    end
  end

  describe "character data" do
    test "plain text" do
      assert tokenize("hello") == [%Token.Character{data: "hello"}]
    end

    test "text between tags" do
      assert [
               %Token.StartTag{name: "p"},
               %Token.Character{data: "hi"},
               %Token.EndTag{name: "p"}
             ] = tokenize("<p>hi</p>")
    end
  end

  describe "comments" do
    test "a comment" do
      assert tokenize("<!--note-->") == [%Token.Comment{data: "note"}]
    end

    # WHATWG "EOF in comment": a comment with no closing `-->` still tokenizes up
    # to end-of-input.
    test "an unclosed comment tokenizes to EOF" do
      assert tokenize("<!--unclosed") == [%Token.Comment{data: "unclosed"}]
    end

    # WHATWG "incorrectly-closed-comment": `--!>` also closes the comment.
    test "a --!> closes the comment" do
      assert tokenize("<!-- x --!>y") == [
               %Token.Comment{data: " x "},
               %Token.Character{data: "y"}
             ]
    end

    # WHATWG "abrupt-closing-of-empty-comment": `<!-->` and `<!--->` are empty.
    test "an abrupt close yields an empty comment" do
      assert tokenize("<!-->x") == [%Token.Comment{data: ""}, %Token.Character{data: "x"}]
      assert tokenize("<!--->x") == [%Token.Comment{data: ""}, %Token.Character{data: "x"}]
    end
  end

  describe "bogus comments" do
    # WHATWG bogus comment: `<?` KEEPS the `?` in the comment data.
    test "a processing-instruction-like `<?...>` keeps the ?" do
      assert tokenize(~s(<?xml version="1.0">)) == [%Token.Comment{data: ~s(?xml version="1.0")}]
    end

    # `<!` that is not a valid comment/doctype DROPS the `!`.
    test "a `<!...>` that is not a comment/doctype drops the bang" do
      assert tokenize("<!COMMENT>") == [%Token.Comment{data: "COMMENT"}]
    end

    # `</` followed by a non-letter DROPS the slash.
    test "a `</` followed by a non-letter is a bogus comment" do
      assert tokenize("</ COMMENT >") == [%Token.Comment{data: " COMMENT "}]
    end

    # A bogus comment is EOF-tolerant.
    test "a bogus comment with no `>` tokenizes to EOF" do
      assert tokenize("<?x") == [%Token.Comment{data: "?x"}]
    end
  end

  describe "malformed tags" do
    # `<>` (empty tag name) is literal character data.
    test "an empty tag `<>` is character data" do
      assert tokenize("<>") == [%Token.Character{data: "<>"}]
    end

    # A bare `</` at end of input is character data.
    test "a bare `</` is character data" do
      assert tokenize("</") == [%Token.Character{data: "</"}]
    end

    # A stray `<` at EOF recovers as character data (tolerant tail-emit) rather
    # than raising.
    test "a stray `<` recovers as character data" do
      assert tokenize("<") == [%Token.Character{data: "<"}]
    end
  end

  describe "doctype" do
    test "a doctype, name lowercased" do
      assert [%Token.Doctype{name: "html"}] = tokenize("<!DOCTYPE HTML>")
    end

    test "a doctype with public and system identifiers" do
      assert [%Token.Doctype{name: "html", public_id: "pub", system_id: "sys"}] =
               tokenize(~s(<!DOCTYPE html PUBLIC "pub" "sys">))
    end

    # WHATWG doctype state: no space is required after the keyword.
    test "a doctype needs no space after the keyword" do
      assert [%Token.Doctype{name: "html"}] = tokenize("<!DOCTYPEhtml>")
    end

    # A doctype with no name still tokenizes (empty name).
    test "a nameless doctype tokenizes with an empty name" do
      assert [%Token.Doctype{name: ""}] = tokenize("<!DOCTYPE>")
    end

    # Junk after the name is consumed and ignored (force-quirks in the tree).
    test "junk after the name is ignored" do
      assert [%Token.Doctype{name: "potato", public_id: nil, system_id: nil}] =
               tokenize("<!DOCTYPE potato taco>")
    end

    # A SYSTEM-only doctype captures the system id.
    test "a SYSTEM-only doctype captures the system id" do
      assert [%Token.Doctype{name: "potato", public_id: nil, system_id: "taco"}] =
               tokenize("<!DOCTYPE potato SYSTEM 'taco'>")
    end

    # A single-quoted public id ends at the next single quote (a nested quote
    # terminates it early).
    test "a public id ends at its matching quote" do
      assert [%Token.Doctype{public_id: "go"}] = tokenize("<!DOCTYPE potato PUBLIC 'go'of'>")
    end
  end

  describe "raw-text elements" do
    test "script interior is one character token, not tokenized" do
      assert [
               %Token.StartTag{name: "script"},
               %Token.Character{data: "if (a < b) { }"},
               %Token.EndTag{name: "script"}
             ] = tokenize("<script>if (a < b) { }</script>")
    end

    test "style interior with markup-looking content" do
      assert [%Token.StartTag{name: "style"}, %Token.Character{data: ".x > .y {}"}, _] =
               tokenize("<style>.x > .y {}</style>")
    end

    # A document <title> is RCDATA: `foo/title>` (a `/`, not `</`) does not close
    # it, so the whole run is one Character token (up to EOF).
    test "an unclosed document <title> is RCDATA to EOF" do
      assert [%Token.StartTag{name: "title"}, %Token.Character{data: "foo/title><b>"}] =
               tokenize("<title>foo/title><b>")
    end

    # Inside SVG foreign content, <title> is an ORDINARY element (foreign-depth
    # context): its interior is tokenized as markup, not captured as raw text.
    test "a <title> inside <svg> tokenizes its interior as markup" do
      assert [
               %Token.StartTag{name: "svg"},
               %Token.StartTag{name: "title"},
               %Token.StartTag{name: "b"},
               %Token.Character{data: "x"},
               %Token.EndTag{name: "b"},
               %Token.EndTag{name: "title"} | _
             ] = tokenize("<svg><title><b>x</b></title></svg>")
    end

    # Leaving the SVG subtree restores HTML tokenization: a <title> AFTER </svg> is
    # RCDATA again.
    test "a <title> after </svg> is RCDATA again" do
      assert [
               %Token.StartTag{name: "svg"},
               %Token.EndTag{name: "svg"},
               %Token.StartTag{name: "title"},
               %Token.Character{data: "a<b>c"},
               %Token.EndTag{name: "title"}
             ] = tokenize("<svg></svg><title>a<b>c</title>")
    end

    test "a script with attributes" do
      assert [%Token.StartTag{name: "script", attributes: [{"src", "a.js"}]} | _] =
               tokenize(~s(<script src="a.js">x</script>))
    end

    test "an empty raw-text element still yields a character token" do
      assert [
               %Token.StartTag{name: "script"},
               %Token.Character{data: ""},
               %Token.EndTag{name: "script"}
             ] = tokenize("<script></script>")
    end

    test "raw-text embedded in a document keeps order" do
      assert [
               %Token.StartTag{name: "div"},
               %Token.StartTag{name: "script"},
               %Token.Character{data: "x"},
               %Token.EndTag{name: "script"},
               %Token.EndTag{name: "div"}
             ] = tokenize("<div><script>x</script></div>")
    end

    test "the close tag is matched case-insensitively" do
      assert [_, %Token.Character{data: "x"}, %Token.EndTag{name: "script"}] =
               tokenize("<script>x</SCRIPT>")
    end

    # WHATWG "EOF in script data": an unclosed script/style/... tokenizes its
    # interior up to end-of-input, with no end tag.
    test "an unclosed script tokenizes its interior to EOF, no end tag" do
      assert tokenize("<script>foo") == [
               %Token.StartTag{name: "script", attributes: [], self_closing: false},
               %Token.Character{data: "foo"}
             ]
    end

    test "an unclosed style tokenizes to EOF" do
      assert [%Token.StartTag{name: "style"}, %Token.Character{data: ".a{}"}] =
               tokenize("<style>.a{}")
    end

    # WHATWG end-tag states: a close tag terminated by whitespace (not `>`) at EOF
    # still closes the element (the trailing junk is dropped, eof-in-tag).
    test "a close tag terminated by whitespace at EOF still closes" do
      assert [
               %Token.StartTag{name: "script"},
               %Token.Character{data: "x"},
               %Token.EndTag{name: "script"}
             ] = tokenize("<script>x</SCRIPT ")
    end

    # A `</name` not followed by a terminator is not a close — it stays raw text.
    test "a </name without a terminator is not a close" do
      assert [%Token.StartTag{name: "script"}, %Token.Character{data: "</scriptx"}] =
               tokenize("<script></scriptx")
    end

    # WHATWG PLAINTEXT state: everything after <plaintext> is one character run to
    # EOF — no tags, no close tag.
    test "plaintext consumes the rest of the input as one character token" do
      assert tokenize("<plaintext><div>foo</div>") == [
               %Token.StartTag{name: "plaintext", attributes: [], self_closing: false},
               %Token.Character{data: "<div>foo</div>"}
             ]
    end

    # WHATWG script-data-escaped: after `<!--`, a bare </script> still CLOSES the
    # element (this input closes at the first </script>).
    test "a bare </script> inside a script comment still closes the script" do
      assert [_, %Token.Character{data: " <!-- "}, %Token.EndTag{name: "script"} | _] =
               tokenize("<script> <!-- </script> --> </script>")
    end

    # WHATWG script-data-double-escaped: a nested <script>...</script> inside the
    # `<!-- -->` escape hides its own </script>, so the real close is the last one.
    test "a nested script inside a comment is double-escaped, not a close" do
      assert [
               _,
               %Token.Character{data: "<!--<script></script>-->"},
               %Token.EndTag{name: "script"}
             ] = tokenize("<script><!--<script></script>--></script>")
    end

    # Without a `<!--`, a nested <script> is NOT double-escaped: the first
    # </script> closes the outer script.
    test "a nested script without a comment closes at the first </script>" do
      assert [_, %Token.Character{data: "<script>"}, %Token.EndTag{name: "script"} | _] =
               tokenize("<script><script></script></script>")
    end
  end

  # The WHATWG script-data escape / double-escape state machine, asserted against
  # the html5lib tree-construction expectations (scripting DISABLED). Each entry
  # is {input, expected <script> interior}. `script_interior/1` returns the single
  # Character run between the <script> start and its real close.
  describe "script-data escape state machine" do
    # `<script` (the double-escape start) is recognized when followed by ANY of
    # whitespace / `/` / `>` — the tag name need not be closed with `>`.
    test "a nested <script followed by whitespace enters double-escape" do
      # inside `<!--`, `<script ` starts double-escape, so the following </script>
      # does NOT close the outer element.
      assert script_interior("<script><!--<script </script>") == "<!--<script </script>"
    end

    # In double-escape, a </script> returns to (single) escaped; a LATER </script>
    # (whitespace/EOF terminated) then closes the outer script.
    test "the second </script> closes after a double-escape returns to escaped" do
      assert script_interior("<script><!--<script </script </script ") ==
               "<!--<script </script "

      assert script_interior("<script><!--<script </script </script>") ==
               "<!--<script </script "
    end

    # `-->` ends the escaped state; a following </script> then closes normally.
    test "--> ends the escape, then </script> closes" do
      assert script_interior("<script><!--<script --></script>") == "<!--<script -->"
      assert script_interior("<script><!--<script --></script ") == "<!--<script -->"
    end

    # In (single) escaped state (no nested <script>), a </script> — even
    # whitespace/EOF terminated — closes.
    test "a </script in escaped state closes at EOF" do
      assert script_interior("<script><!--</script ") == "<!--"
    end

    # A fully nested-and-closed double-escape keeps everything up to the outer
    # close (regression guard for the already-passing shape).
    test "a complete double-escape keeps its interior" do
      assert script_interior("<script><!--<script></script>--></script>") ==
               "<!--<script></script>-->"
    end

    # Two nested <script></script> pairs, then the outer close.
    test "multiple nested pairs before the close" do
      assert script_interior("<script><!--<script></script><script></script>--></script>") ==
               "<!--<script></script><script></script>-->"
    end
  end

  describe "multibyte text" do
    test "non-ASCII characters survive tokenization as valid UTF-8" do
      assert [%Token.Character{data: "café → 日本"}] = tokenize("café → 日本")
    end

    test "non-ASCII in a comment" do
      assert [%Token.Comment{data: "café"}] = tokenize("<!--café-->")
    end
  end

  describe "entity decoding (via Token.decode/1)" do
    defp decode(html), do: html |> DOM.HTML.tokenize() |> Enum.map(&Token.decode/1)

    test "named references in text" do
      assert [%Token.Character{data: "a & b < c"}] = decode("a &amp; b &lt; c")
    end

    test "numeric decimal and hex references" do
      assert [%Token.Character{data: "& & ©"}] = decode("&#38; &#x26; &#169;")
    end

    test "longest match wins" do
      assert [%Token.Character{data: "∉"}] = decode("&notin;")
    end

    test "attribute values are decoded" do
      assert [%Token.StartTag{attributes: [{"title", "a&b"}]}] =
               decode(~s(<a title="a&amp;b">))
    end

    test "a bare ampersand is left literal" do
      assert [%Token.Character{data: "a & b"}] = decode("a & b")
    end
  end
end
