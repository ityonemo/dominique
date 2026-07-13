defmodule DOM.ValidityTest do
  use DOM.Case, async: true

  # Constraint validation pseudo-classes, derived from attributes + the value attribute
  # (no live editing modeled). Browser-verified in constraint-validation-semantics memory.

  defp q(doc, sel), do: DOM.query_selector(doc, sel)

  describe "participation" do
    test "a non-form element matches neither :valid nor :invalid" do
      doc = new_document("<body><div id='d'></div></body>")
      refute DOM.matches(q(doc, "#d"), ":valid")
      refute DOM.matches(q(doc, "#d"), ":invalid")
    end

    test "an unconstrained input is :valid" do
      doc = new_document("<body><input id='i'></body>")
      assert DOM.matches(q(doc, "#i"), ":valid")
      refute DOM.matches(q(doc, "#i"), ":invalid")
    end

    test "a disabled control is barred (neither :valid nor :invalid)" do
      doc = new_document("<body><input id='d' required disabled></body>")
      refute DOM.matches(q(doc, "#d"), ":valid")
      refute DOM.matches(q(doc, "#d"), ":invalid")
    end
  end

  describe ":invalid sources" do
    test "required + empty is :invalid; required + filled is :valid" do
      doc = new_document("<body><input id='a' required><input id='b' required value='x'></body>")
      assert DOM.matches(q(doc, "#a"), ":invalid")
      refute DOM.matches(q(doc, "#b"), ":invalid")
      assert DOM.matches(q(doc, "#b"), ":valid")
    end

    test "type=email with a bad value is :invalid; good is :valid" do
      doc =
        new_document(
          "<body><input id='e' type='email' value='notanemail'>" <>
            "<input id='e2' type='email' value='a@b.com'></body>"
        )

      assert DOM.matches(q(doc, "#e"), ":invalid")
      assert DOM.matches(q(doc, "#e2"), ":valid")
    end

    test "pattern mismatch is :invalid; match is :valid" do
      doc =
        new_document(
          "<body><input id='p' pattern='[0-9]+' value='abc'>" <>
            "<input id='p2' pattern='[0-9]+' value='123'></body>"
        )

      assert DOM.matches(q(doc, "#p"), ":invalid")
      assert DOM.matches(q(doc, "#p2"), ":valid")
    end
  end

  describe ":in-range / :out-of-range" do
    setup do
      doc =
        new_document(
          "<body><input id='lo' type='number' min='5' max='10' value='3'>" <>
            "<input id='ok' type='number' min='5' max='10' value='7'>" <>
            "<input id='hi' type='number' min='5' max='10' value='15'>" <>
            "<input id='plain' value='x'></body>"
        )

      %{doc: doc}
    end

    test "a value below min or above max is :out-of-range and :invalid", %{doc: doc} do
      assert DOM.matches(q(doc, "#lo"), ":out-of-range")
      assert DOM.matches(q(doc, "#lo"), ":invalid")
      assert DOM.matches(q(doc, "#hi"), ":out-of-range")
    end

    test "a value within min..max is :in-range and :valid", %{doc: doc} do
      assert DOM.matches(q(doc, "#ok"), ":in-range")
      assert DOM.matches(q(doc, "#ok"), ":valid")
      refute DOM.matches(q(doc, "#ok"), ":out-of-range")
    end

    test "a non-range input matches neither :in-range nor :out-of-range", %{doc: doc} do
      refute DOM.matches(q(doc, "#plain"), ":in-range")
      refute DOM.matches(q(doc, "#plain"), ":out-of-range")
    end
  end
end
