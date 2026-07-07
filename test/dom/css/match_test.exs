defmodule DOM.CSS.MatchTest do
  use ExUnit.Case, async: true

  # match/3 is scaffolded but not yet implemented; this locks the contract until
  # the matcher arc fills it in.

  test "match/3 raises unimplemented for every selector struct" do
    for selector <- [
          "div",
          "*",
          "#main",
          ".box",
          "[href]",
          "a:hover",
          ":nth-child(2n+1)",
          ":not(.x)",
          "::before",
          "a > b",
          ".a, .b"
        ],
        node <- DOM.CSS.parse(selector) do
      assert_raise RuntimeError, "unimplemented", fn ->
        DOM.CSS.match(node, :nodes, [])
      end
    end
  end
end
