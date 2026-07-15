defmodule DOM.AnylinkPlaceholderTest do
  use DOM.Case, async: true

  # :any-link — an a/area with href (like :link; visitedness not modeled).
  # :placeholder-shown — an input/textarea with a placeholder attribute and empty value.
  # Browser-verified.

  describe ":any-link" do
    test "matches a/area with href, not a bare anchor" do
      doc =
        new_document(
          "<body><a id='a1' href='#'>x</a><a id='a2'>x</a><area id='ar' href='#'></body>"
        )

      assert DOM.Element.matches(DOM.query_selector(doc, "#a1"), ":any-link")
      refute DOM.Element.matches(DOM.query_selector(doc, "#a2"), ":any-link")
      assert DOM.Element.matches(DOM.query_selector(doc, "#ar"), ":any-link")
    end
  end

  describe ":placeholder-shown" do
    test "an empty input with a placeholder is :placeholder-shown" do
      doc =
        new_document(
          "<body><input id='e' placeholder='p'><input id='v' placeholder='p' value='hi'>" <>
            "<input id='np'></body>"
        )

      assert DOM.Element.matches(DOM.query_selector(doc, "#e"), ":placeholder-shown")
      # has a value -> placeholder not shown
      refute DOM.Element.matches(DOM.query_selector(doc, "#v"), ":placeholder-shown")
      # no placeholder attribute
      refute DOM.Element.matches(DOM.query_selector(doc, "#np"), ":placeholder-shown")
    end

    test "an empty textarea with a placeholder is :placeholder-shown; with content is not" do
      doc =
        new_document(
          "<body><textarea id='ta' placeholder='p'></textarea>" <>
            "<textarea id='tav' placeholder='p'>content</textarea></body>"
        )

      assert DOM.Element.matches(DOM.query_selector(doc, "#ta"), ":placeholder-shown")
      refute DOM.Element.matches(DOM.query_selector(doc, "#tav"), ":placeholder-shown")
    end
  end
end
