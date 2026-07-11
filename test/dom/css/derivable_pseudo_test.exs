defmodule DOM.CSS.DerivablePseudoTest do
  use DOM.Case, async: true

  # T8b: the two derivable CSS pseudos that are pure tree/ancestor walks —
  # :read-write contenteditable INHERITANCE, and :default DEFAULT SUBMIT BUTTON.

  describe ":read-write contenteditable inheritance" do
    setup do
      doc =
        new_document("""
        <div contenteditable='true'>
          <p id='inherit'>x</p>
          <div contenteditable='false'><p id='blocked'>y</p></div>
        </div>
        <p id='outside'>z</p>
        """)

      %{doc: doc}
    end

    test "an element inside a contenteditable=true ancestor is :read-write", %{doc: doc} do
      assert DOM.matches(DOM.query_selector(doc, "#inherit"), ":read-write")
    end

    test "a contenteditable=false ancestor blocks inheritance", %{doc: doc} do
      refute DOM.matches(DOM.query_selector(doc, "#blocked"), ":read-write")
    end

    test "an element with no contenteditable ancestor is not :read-write", %{doc: doc} do
      refute DOM.matches(DOM.query_selector(doc, "#outside"), ":read-write")
    end

    test "the contenteditable host itself is :read-write", %{doc: doc} do
      host = DOM.query_selector(doc, "div[contenteditable='true']")
      assert DOM.matches(host, ":read-write")
    end
  end

  describe ":default default submit button" do
    setup do
      doc =
        new_document("""
        <form>
          <button id='b1'>a</button>
          <button id='b2'>b</button>
          <input id='i1' type='submit'>
        </form>
        """)

      %{doc: doc}
    end

    test "the first submit-capable control in the form is :default", %{doc: doc} do
      assert DOM.matches(DOM.query_selector(doc, "#b1"), ":default")
    end

    test "later submit controls are not :default", %{doc: doc} do
      refute DOM.matches(DOM.query_selector(doc, "#b2"), ":default")
      refute DOM.matches(DOM.query_selector(doc, "#i1"), ":default")
    end

    test "an input[type=submit] is the default when it is first" do
      doc = new_document("<form><input id='s' type='submit'><button id='b'>x</button></form>")
      assert DOM.matches(DOM.query_selector(doc, "#s"), ":default")
      refute DOM.matches(DOM.query_selector(doc, "#b"), ":default")
    end

    test "the already-handled checked-input / selected-option cases still match" do
      doc =
        new_document(
          "<input type='checkbox' id='c' checked><select><option id='o' selected></option></select>"
        )

      assert DOM.matches(DOM.query_selector(doc, "#c"), ":default")
      assert DOM.matches(DOM.query_selector(doc, "#o"), ":default")
    end
  end
end
