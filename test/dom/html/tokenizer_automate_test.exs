defmodule DOM.HTML.TokenizerAutomateTest do
  use ExUnit.Case, async: true

  # Data-driven from the vendored html5lib-tests tokenizer suite. One test per
  # applicable case (Data state, no error recovery, no entity decoding). See
  # HTML5lib for the skip rules and the token<->array conversion.

  @files ~w(test1.test test2.test test4.test)

  for file <- @files do
    for test_case <- HTML5lib.cases(file) do
      @input test_case["input"]
      @expected HTML5lib.coalesce_characters(test_case["output"])
      @description "#{file}: #{test_case["description"]}"

      test @description do
        actual = @input |> DOM.HTML.tokenize() |> HTML5lib.to_html5lib()
        assert actual == @expected
      end
    end
  end
end
