defmodule DOM.Node.Element.LocalNameTest do
  use ExUnit.Case, async: true

  alias DOM.Element

  test "returns an element's creation name and nil for a document" do
    document = DOM.new()
    element = DOM.create_element(document, "x-element")

    assert Element.local_name(element) == "x-element"
    refute Element.local_name(document)
  end
end
