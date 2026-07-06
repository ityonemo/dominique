defmodule DOM.Node.Element.AttributeTest do
  use ExUnit.Case, async: true

  alias DOM.Node.Element

  test "get_attribute returns nil for a missing attribute" do
    document = DOM.new()
    element = DOM.create_element(document, "element")

    assert Element.get_attribute(element, "missing") == nil
  end

  test "set_attribute stores a value that get_attribute reads back" do
    document = DOM.new()
    element = DOM.create_element(document, "element")

    Element.set_attribute(element, "id", "widget")

    assert Element.get_attribute(element, "id") == "widget"
  end

  test "set_attribute overwrites an existing value in place" do
    document = DOM.new()
    element = DOM.create_element(document, "element")
    Element.set_attribute(element, "class", "old")

    Element.set_attribute(element, "class", "new")

    assert Element.get_attribute(element, "class") == "new"
  end

  test "has_attribute reflects presence" do
    document = DOM.new()
    element = DOM.create_element(document, "element")

    refute Element.has_attribute(element, "data-x")
    Element.set_attribute(element, "data-x", "1")
    assert Element.has_attribute(element, "data-x")
  end
end
