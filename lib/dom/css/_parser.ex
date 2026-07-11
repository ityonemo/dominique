defmodule DOM.CSS.Parser do
  @moduledoc false

  # The CSS selector parser, generated at compile time by Pegasus from
  # lib/dom/css/selector.peg. The post_traverse handlers build the DOM.CSS.*
  # struct AST in a single pass. Public entry is DOM.CSS.parse/1, which
  # delegates here; this module lives apart from the DOM.CSS protocol so the
  # struct modules (which `use DOM.CSS`) do not create a compile cycle.

  require Pegasus

  Pegasus.parser_from_file(Path.join(__DIR__, "selector.peg"),
    selector_list: [parser: :parse_selector, post_traverse: :selector_list],
    comma: [ignore: true],
    complex: [tag: true, post_traverse: :complex],
    combinator: [post_traverse: :combinator],
    descendant: [token: :descendant],
    ws: [ignore: true],
    compound: [tag: true, post_traverse: :compound],
    universal: [tag: true, post_traverse: :universal],
    id: [post_traverse: :id],
    class: [post_traverse: :class],
    type: [tag: true, post_traverse: :type],
    namespace: [tag: true, post_traverse: :namespace],
    ns_prefix: [collect: true],
    pseudo_element: [post_traverse: :pseudo_element],
    functional_pseudo_element: [tag: true, post_traverse: :functional_pseudo_element],
    fpe_name: [collect: true],
    pseudo_class: [post_traverse: :pseudo_class],
    negation: [tag: true, post_traverse: :negation],
    functional_selector: [tag: true, post_traverse: :functional_selector],
    func_sel_name: [collect: true],
    has: [tag: true, post_traverse: :has],
    relative_list: [tag: true],
    relative_complex: [tag: true, post_traverse: :relative_complex],
    functional_args: [tag: true, post_traverse: :functional_args],
    selector_list_inner: [tag: true],
    nth: [tag: true, post_traverse: :nth],
    nth_name: [collect: true],
    nth_of: [tag: true],
    anb: [collect: true, post_traverse: :anb],
    attribute: [tag: true, post_traverse: :attribute],
    attr_op: [collect: true, post_traverse: :attr_op],
    attr_value: [tag: true, post_traverse: :attr_value],
    attr_string: [collect: true, post_traverse: :attr_string],
    attr_flag: [collect: true, post_traverse: :attr_flag],
    name: [tag: true, post_traverse: :name],
    plain_char: [collect: true],
    multibyte_utf8: [collect: true],
    escape: [post_traverse: :escape],
    hex_escape: [collect: true, tag: :hex_escape],
    char_escape: [collect: true, tag: :char_escape]
  )

  @spec parse(String.t()) :: DOM.CSS.t()
  def parse(selector) do
    case parse_selector(selector) do
      {:ok, [ast], "", _context, _loc, _offset} ->
        ast

      {:ok, _ast, rest, _context, _loc, _offset} ->
        raise ArgumentError,
              "invalid CSS selector #{inspect(selector)} (unparsed: #{inspect(rest)})"

      {:error, reason, _rest, _context, _loc, _offset} ->
        raise ArgumentError, "invalid CSS selector #{inspect(selector)}: #{reason}"
    end
  end

  # ==========================================================================
  # Semantic actions (build structs; args arrive as a reversed stack)
  # ==========================================================================

  defp selector_list(rest, complexes, context, _loc, _col) do
    {rest, [Enum.reverse(complexes)], context}
  end

  # A complex with no combinator collapses to its single compound; otherwise a
  # DOM.CSS.Complex holds the alternating compounds and combinators.
  defp complex(rest, [{:complex, [compound]}], context, _loc, _col) do
    {rest, [compound], context}
  end

  defp complex(rest, [{:complex, parts}], context, _loc, _col) do
    {rest, [%DOM.CSS.Complex{parts: parts}], context}
  end

  @combinators %{">" => :child, "+" => :next_sibling, "~" => :subsequent_sibling}

  defp combinator(rest, [:descendant], context, _loc, _col) do
    {rest, [:descendant], context}
  end

  defp combinator(rest, [delimiter], context, _loc, _col) do
    {rest, [Map.fetch!(@combinators, delimiter)], context}
  end

  defp compound(rest, [{:compound, simples}], context, _loc, _col) do
    {rest, [%DOM.CSS.Compound{simples: simples}], context}
  end

  defp id(rest, [name, "#"], context, _loc, _col) do
    {rest, [%DOM.CSS.Id{name: name}], context}
  end

  defp class(rest, [name, "."], context, _loc, _col) do
    {rest, [%DOM.CSS.Class{name: name}], context}
  end

  defp type(rest, [{:type, [name]}], context, _loc, _col) do
    {rest, [%DOM.CSS.Type{name: name}], context}
  end

  defp type(rest, [{:type, [{:ns, ns}, name]}], context, _loc, _col) do
    {rest, [%DOM.CSS.Type{name: name, namespace: ns}], context}
  end

  defp universal(rest, [{:universal, ["*"]}], context, _loc, _col) do
    {rest, [%DOM.CSS.Universal{}], context}
  end

  defp universal(rest, [{:universal, [{:ns, ns}, "*"]}], context, _loc, _col) do
    {rest, [%DOM.CSS.Universal{namespace: ns}], context}
  end

  # namespace prefix -> {:ns, "svg" | :any | :none}; "*|" is any, "|"/"" is none.
  defp namespace(rest, [{:namespace, ["*", "|"]}], context, _loc, _col) do
    {rest, [{:ns, :any}], context}
  end

  defp namespace(rest, [{:namespace, [prefix, "|"]}], context, _loc, _col) when prefix != "" do
    {rest, [{:ns, prefix}], context}
  end

  defp namespace(rest, [{:namespace, parts}], context, _loc, _col)
       when parts == ["|"] or parts == ["", "|"] do
    {rest, [{:ns, :none}], context}
  end

  @attr_ops %{
    "=" => :eq,
    "~=" => :includes,
    "|=" => :dash,
    "^=" => :prefix,
    "$=" => :suffix,
    "*=" => :substring
  }

  defp attr_op(rest, [op], context, _loc, _col) do
    {rest, [{:op, Map.fetch!(@attr_ops, op)}], context}
  end

  defp attr_string(rest, [quoted], context, _loc, _col) do
    {rest, [String.slice(quoted, 1..-2//1)], context}
  end

  defp attr_value(rest, [{:attr_value, [value]}], context, _loc, _col) do
    {rest, [{:value, value}], context}
  end

  defp attr_flag(rest, [flag], context, _loc, _col) do
    {rest, [{:flag, String.to_atom(String.trim(flag))}], context}
  end

  defp attribute(rest, [{:attribute, parts}], context, _loc, _col) do
    {rest, [build_attribute(namespace_attr(parts))], context}
  end

  # Fold a leading namespace prefix into the attribute struct's namespace field.
  defp namespace_attr(["[", {:ns, ns}, name | rest]), do: {ns, ["[", name | rest]}
  defp namespace_attr(parts), do: {nil, parts}

  defp build_attribute({ns, ["[", name, "]"]}), do: %DOM.CSS.Attribute{name: name, namespace: ns}

  defp build_attribute({ns, ["[", name, {:op, op}, {:value, value}, "]"]}) do
    %DOM.CSS.Attribute{name: name, namespace: ns, op: op, value: value}
  end

  defp build_attribute({ns, ["[", name, {:op, op}, {:value, value}, {:flag, flag}, "]"]}) do
    %DOM.CSS.Attribute{name: name, namespace: ns, op: op, value: value, flag: flag}
  end

  defp pseudo_element(rest, [name, "::"], context, _loc, _col) do
    {rest, [%DOM.CSS.PseudoElement{name: name}], context}
  end

  defp functional_pseudo_element(
         rest,
         [{:functional_pseudo_element, ["::", name, "(", {:selector_list_inner, list}, ")"]}],
         ctx,
         _loc,
         _col
       ) do
    {rest, [%DOM.CSS.PseudoElement{name: name, arg: {:selector_list, list}}], ctx}
  end

  defp pseudo_class(rest, [name, ":"], context, _loc, _col) do
    {rest, [%DOM.CSS.PseudoClass{name: name}], context}
  end

  defp nth(rest, [{:nth, [":", name, "(", {a, b}, ")"]}], context, _loc, _col) do
    {rest, [%DOM.CSS.PseudoClass{name: name, arg: {a, b}}], context}
  end

  defp nth(
         rest,
         [{:nth, [":", name, "(", {a, b}, {:nth_of, of_parts}, ")"]}],
         context,
         _loc,
         _col
       ) do
    {:selector_list_inner, list} = List.keyfind(of_parts, :selector_list_inner, 0)
    {rest, [%DOM.CSS.PseudoClass{name: name, arg: {a, b, list}}], context}
  end

  defp negation(
         rest,
         [{:negation, [":not(", {:selector_list_inner, list}, ")"]}],
         ctx,
         _loc,
         _col
       ) do
    {rest, [%DOM.CSS.PseudoClass{name: "not", arg: {:selector_list, list}}], ctx}
  end

  defp functional_selector(
         rest,
         [{:functional_selector, [":", name, "(", {:selector_list_inner, list}, ")"]}],
         ctx,
         _loc,
         _col
       ) do
    {rest, [%DOM.CSS.PseudoClass{name: name, arg: {:selector_list, list}}], ctx}
  end

  # :has produces its pseudo-class directly; functional_selector just unwraps it.
  defp functional_selector(rest, [{:functional_selector, [pseudo_class]}], ctx, _loc, _col) do
    {rest, [pseudo_class], ctx}
  end

  defp has(rest, [{:has, [":has(", {:relative_list, complexes}, ")"]}], ctx, _loc, _col) do
    {rest, [%DOM.CSS.PseudoClass{name: "has", arg: {:selector_list, complexes}}], ctx}
  end

  # A relative complex may lead with a combinator; a plain complex passes through.
  defp relative_complex(rest, [{:relative_complex, [complex]}], ctx, _loc, _col) do
    {rest, [complex], ctx}
  end

  defp relative_complex(rest, [{:relative_complex, [combinator, complex]}], ctx, _loc, _col) do
    parts =
      case complex do
        %DOM.CSS.Complex{parts: parts} -> [combinator | parts]
        compound -> [combinator, compound]
      end

    {rest, [%DOM.CSS.Complex{parts: parts}], ctx}
  end

  defp functional_args(rest, [{:functional_args, [":", name, "(" | rest_parts]}], ctx, _loc, _col) do
    args = Enum.reject(rest_parts, &(&1 == ")"))
    {rest, [%DOM.CSS.PseudoClass{name: name, arg: {:args, args}}], ctx}
  end

  # An+B micro-syntax -> {a, b}; whitespace inside is normalized here.
  defp anb(rest, [text], context, _loc, _col) do
    {rest, [parse_anb(text)], context}
  end

  defp parse_anb("odd"), do: {2, 1}
  defp parse_anb("even"), do: {2, 0}

  defp parse_anb(text) do
    text = String.replace(text, " ", "")

    case String.split(text, "n", parts: 2) do
      [b] -> {0, String.to_integer(b)}
      [coeff, rest] -> {anb_coeff(coeff), anb_b(rest)}
    end
  end

  defp anb_coeff(""), do: 1
  defp anb_coeff("-"), do: -1
  defp anb_coeff("+"), do: 1
  defp anb_coeff(n), do: String.to_integer(n)

  defp anb_b(""), do: 0
  defp anb_b(rest), do: String.to_integer(rest)

  # name_chars arrive in source order; join the decoded characters.
  defp name(rest, [{:name, chars}], context, _loc, _col) do
    {rest, [IO.iodata_to_binary(chars)], context}
  end

  # A hex escape ("\" + 1-6 hex digits + optional trailing space) -> code point;
  # a char escape ("\" + one non-hex char) -> that literal character.
  defp escape(rest, [{:hex_escape, [hex]}, "\\"], context, _loc, _col) do
    codepoint = hex |> String.trim() |> String.to_integer(16)
    {rest, [<<codepoint::utf8>>], context}
  end

  defp escape(rest, [{:char_escape, [char]}, "\\"], context, _loc, _col) do
    {rest, [char], context}
  end
end
