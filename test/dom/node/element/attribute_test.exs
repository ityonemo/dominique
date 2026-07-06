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

  test "remove_attribute deletes a present attribute" do
    document = DOM.new()
    element = DOM.create_element(document, "element")
    Element.set_attribute(element, "id", "widget")

    Element.remove_attribute(element, "id")

    refute Element.has_attribute(element, "id")
    assert Element.get_attribute(element, "id") == nil
  end

  test "remove_attribute is a no-op for a missing attribute" do
    document = DOM.new()
    element = DOM.create_element(document, "element")
    Element.set_attribute(element, "keep", "yes")

    Element.remove_attribute(element, "absent")

    assert Element.get_attribute(element, "keep") == "yes"
  end

  test "get_attribute_names lists names in insertion order" do
    document = DOM.new()
    element = DOM.create_element(document, "element")
    Element.set_attribute(element, "b", "2")
    Element.set_attribute(element, "a", "1")
    Element.set_attribute(element, "c", "3")
    Element.set_attribute(element, "a", "override")

    assert Element.get_attribute_names(element) == ["b", "a", "c"]
  end

  test "get_attribute_names is empty for a bare element" do
    document = DOM.new()
    element = DOM.create_element(document, "element")

    assert Element.get_attribute_names(element) == []
  end
end
