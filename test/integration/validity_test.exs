defmodule Integration.ValidityTest do
  use ExUnit.Case, async: true
  use Playwright

  @moduletag :integration

  playwright do
    @link "https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api"

    # :valid/:invalid/:in-range/:out-of-range across the constraint matrix. We build
    # the same controls and compare the pseudo-class matches.
    @js """
    return await page.evaluate(() => {
      const host = document.createElement("div");
      host.innerHTML =
        "<input id='u'>" +
        "<div id='d'></div>" +
        "<input id='dis' required disabled>" +
        "<input id='req'>" +
        "<input id='reqf' required value='x'>" +
        "<input id='email' type='email' value='bad'>" +
        "<input id='pat' pattern='[0-9]+' value='abc'>" +
        "<input id='lo' type='number' min='5' max='10' value='3'>" +
        "<input id='ok' type='number' min='5' max='10' value='7'>" +
        "<input id='hi' type='number' min='5' max='10' value='15'>" +
        "<input id='plain' value='x'>";
      document.body.appendChild(host);
      const $ = (s) => host.querySelector(s);
      const m = (s, p) => $(s).matches(p);

      const out = {
        u_valid: m("#u", ":valid"),
        d_valid: m("#d", ":valid"), d_invalid: m("#d", ":invalid"),
        dis_valid: m("#dis", ":valid"), dis_invalid: m("#dis", ":invalid"),
        req_invalid: m("#req", ":invalid"),
        reqf_valid: m("#reqf", ":valid"),
        email_invalid: m("#email", ":invalid"),
        pat_invalid: m("#pat", ":invalid"),
        lo_oor: m("#lo", ":out-of-range"), lo_invalid: m("#lo", ":invalid"),
        ok_ir: m("#ok", ":in-range"), ok_valid: m("#ok", ":valid"),
        hi_oor: m("#hi", ":out-of-range"),
        plain_ir: m("#plain", ":in-range"), plain_oor: m("#plain", ":out-of-range"),
      };
      document.body.removeChild(host);
      return out;
    });
    """

    test "constraint validation pseudos match the browser", %{js: expected} do
      doc =
        DOM.new(
          "<body><input id='u'><div id='d'></div><input id='dis' required disabled>" <>
            "<input id='req'><input id='reqf' required value='x'>" <>
            "<input id='email' type='email' value='bad'>" <>
            "<input id='pat' pattern='[0-9]+' value='abc'>" <>
            "<input id='lo' type='number' min='5' max='10' value='3'>" <>
            "<input id='ok' type='number' min='5' max='10' value='7'>" <>
            "<input id='hi' type='number' min='5' max='10' value='15'>" <>
            "<input id='plain' value='x'></body>"
        )

      m = fn s, p -> DOM.matches(DOM.query_selector(doc, s), p) end

      out = %{
        "u_valid" => m.("#u", ":valid"),
        "d_valid" => m.("#d", ":valid"),
        "d_invalid" => m.("#d", ":invalid"),
        "dis_valid" => m.("#dis", ":valid"),
        "dis_invalid" => m.("#dis", ":invalid"),
        "req_invalid" => m.("#req", ":invalid"),
        "reqf_valid" => m.("#reqf", ":valid"),
        "email_invalid" => m.("#email", ":invalid"),
        "pat_invalid" => m.("#pat", ":invalid"),
        "lo_oor" => m.("#lo", ":out-of-range"),
        "lo_invalid" => m.("#lo", ":invalid"),
        "ok_ir" => m.("#ok", ":in-range"),
        "ok_valid" => m.("#ok", ":valid"),
        "hi_oor" => m.("#hi", ":out-of-range"),
        "plain_ir" => m.("#plain", ":in-range"),
        "plain_oor" => m.("#plain", ":out-of-range")
      }

      assert out == expected
    end
  end
end
