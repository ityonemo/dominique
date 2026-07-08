defmodule DatOutline do
  @moduledoc """
  Serializes a built `%DOM.Node{type: :document}` tree to the html5lib
  tree-construction `#document` outline format, for comparison against the
  vendored `.dat` expectations. Walks the tree through the public handle API
  (no ETS access from test support).

  Line format: `"| "` + two spaces per depth + the node's rendering:
  element `<tag>` (attributes as deeper `name="value"` lines, sorted by name),
  text `"..."`, comment `<!-- data -->`, doctype `<!DOCTYPE name>`.
  """

  alias DOM.Element
  alias DOM.Node

  @doc "Renders the document's subtree as the `.dat` `#document` outline string."
  def serialize(%Node{type: :document} = document) do
    document
    |> Node.child_nodes()
    |> Enum.flat_map(&lines(&1, 0))
    |> Enum.join("\n")
  end

  @doc """
  Renders a fragment (the synthetic `html` root's children) as the `#document`
  outline — the form the html5lib fragment cases expect (no `<html>` wrapper).
  """
  def serialize_fragment(%Node{type: :element} = root) do
    root
    |> Node.child_nodes()
    |> Enum.flat_map(&lines(&1, 0))
    |> Enum.join("\n")
  end

  # Returns the outline lines for a node and its subtree at `depth`. A foreign
  # (SVG/MathML) element gets a `svg `/`math ` namespace prefix before its name.
  defp lines(%Node{type: :element} = element, depth) do
    tag = ["| ", indent(depth), "<", namespace_prefix(element), Node.node_name(element), ">"]
    attrs = attribute_lines(element, depth + 1)
    children = element |> Node.child_nodes() |> Enum.flat_map(&lines(&1, depth + 1))
    [line(tag) | attrs ++ children]
  end

  defp lines(%Node{type: :text} = text, depth) do
    [line(["| ", indent(depth), ?", Node.value(text), ?"])]
  end

  defp lines(%Node{type: :comment} = comment, depth) do
    [line(["| ", indent(depth), "<!-- ", Node.value(comment), " -->"])]
  end

  defp lines(%Node{type: :document_type} = doctype, depth) do
    [line(["| ", indent(depth), "<!DOCTYPE ", Node.node_name(doctype), ">"])]
  end

  # Attributes are dumped as pseudo-children, sorted lexicographically by name.
  defp attribute_lines(element, depth) do
    element
    |> Element.get_attribute_names()
    |> Enum.sort()
    |> Enum.map(fn name ->
      line(["| ", indent(depth), name, "=", ?", Element.get_attribute(element, name), ?"])
    end)
  end

  defp namespace_prefix(element) do
    case Element.namespace(element) do
      :svg -> "svg "
      :mathml -> "math "
      _ -> ""
    end
  end

  defp indent(depth), do: String.duplicate("  ", depth)
  defp line(iodata), do: IO.iodata_to_binary(iodata)
end
