defmodule Integration.DerivablePseudoTest do
  use ExUnit.Case, async: true
  use Playwright

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/#selector-read-write"

    # :read-write contenteditable inheritance + :default default-submit-button,
    # matched via matches() against the browser.
    @js """
    return await page.evaluate(() => {
      const rwDoc = new DOMParser().parseFromString(
        "<div contenteditable='true'><p id='inherit'>x</p>" +
        "<div contenteditable='false'><p id='blocked'>y</p></div></div><p id='outside'>z</p>",
        "text/html");
      const rw = (id) => rwDoc.getElementById(id).matches(":read-write");

      const fDoc = new DOMParser().parseFromString(
        "<form><button id='b1'>a</button><button id='b2'>b</button>" +
        "<input id='i1' type='submit'></form>", "text/html");
      const def = (id) => fDoc.getElementById(id).matches(":default");

      return {
        rw_inherit: rw("inherit"),
        rw_blocked: rw("blocked"),
        rw_outside: rw("outside"),
        def_b1: def("b1"),
        def_b2: def("b2"),
        def_i1: def("i1")
      };
    });
    """

    test ":read-write inheritance + :default submit button match the browser", %{js: expected} do
      rw_doc =
        DOM.new(
          "<div contenteditable='true'><p id='inherit'>x</p>" <>
            "<div contenteditable='false'><p id='blocked'>y</p></div></div><p id='outside'>z</p>"
        )

      rw = fn id -> DOM.Element.matches(DOM.query_selector(rw_doc, "##{id}"), ":read-write") end

      f_doc =
        DOM.new(
          "<form><button id='b1'>a</button><button id='b2'>b</button>" <>
            "<input id='i1' type='submit'></form>"
        )

      def_ = fn id -> DOM.Element.matches(DOM.query_selector(f_doc, "##{id}"), ":default") end

      result = %{
        "rw_inherit" => rw.("inherit"),
        "rw_blocked" => rw.("blocked"),
        "rw_outside" => rw.("outside"),
        "def_b1" => def_.("b1"),
        "def_b2" => def_.("b2"),
        "def_i1" => def_.("i1")
      }

      assert result == expected
    end
  end
end
