defmodule DOM.HTML.TokenizerTest do
  use ExUnit.Case, async: true

  alias DOM.HTML.Token

  defp tokenize(html), do: DOM.HTML.tokenize(html)

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
  end

  describe "doctype" do
    test "a doctype, name lowercased" do
      assert [%Token.Doctype{name: "html"}] = tokenize("<!DOCTYPE HTML>")
    end
  end
end
