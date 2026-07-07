defmodule DOM.CSS.SelectorPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Generators produce only well-formed selector ASTs (ones that serialize to a
  # valid selector), so the round-trip invariants below exercise the whole
  # parse/serialize pipeline without a browser.

  # A CSS identifier value (the decoded AST form). Includes plain idents, a
  # leading digit, and characters that force escaping on serialization, so the
  # round-trip exercises escape/unescape.
  defp ident do
    gen all(
          first <- string([?a..?z, ?A..?Z, ?_, ?0..?9], length: 1),
          rest <- string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_, ?., ?:], max_length: 6)
        ) do
      first <> rest
    end
  end

  defp attr_op, do: member_of([:eq, :includes, :dash, :prefix, :suffix, :substring])

  defp attribute do
    gen all(
          name <- ident(),
          shape <-
            one_of([
              constant(:presence),
              tuple({attr_op(), ident()}),
              tuple({attr_op(), ident(), member_of([:i, :s])})
            ])
        ) do
      case shape do
        :presence -> {:attr, name}
        {op, value} -> {:attr, name, op, value}
        {op, value, flag} -> {:attr, name, op, value, flag}
      end
    end
  end

  defp anb do
    gen all(a <- integer(-5..5), b <- integer(-9..9)) do
      {a, b}
    end
  end

  defp nth do
    gen all(
          name <-
            member_of(["nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type"]),
          ab <- anb()
        ) do
      {:pseudo_class, name, ab}
    end
  end

  # Simple selectors, excluding type/universal (which lead a compound).
  defp subclass do
    one_of([
      gen(all(n <- ident(), do: {:id, n})),
      gen(all(n <- ident(), do: {:class, n})),
      attribute(),
      gen(all(n <- ident(), do: {:pseudo_class, n})),
      nth(),
      gen(all(list <- compound_list(), do: {:not, list})),
      gen(all(n <- ident(), do: {:pseudo_element, n}))
    ])
  end

  # A compound: an optional leading type-or-universal, then zero+ subclasses,
  # but never empty.
  defp compound do
    gen all(
          lead <-
            one_of([
              constant([]),
              gen(all(n <- ident(), do: [{:type, n}])),
              constant([:universal])
            ]),
          subs <- list_of(subclass(), max_length: 3),
          simples = lead ++ subs,
          simples != []
        ) do
      {:compound, simples}
    end
  end

  # A list of compounds (used by :not); non-empty.
  defp compound_list do
    gen all(compounds <- list_of(compound(), min_length: 1, max_length: 3)) do
      compounds
    end
  end

  defp combinator, do: member_of([:descendant, :child, :next_sibling, :subsequent_sibling])

  # A complex selector: a compound, optionally followed by combinator+compound
  # pairs. A lone compound collapses (matching how parse/1 returns it).
  defp complex do
    gen all(
          head <- compound(),
          tail <- list_of(tuple({combinator(), compound()}), max_length: 3)
        ) do
      case tail do
        [] -> head
        pairs -> [head | Enum.flat_map(pairs, fn {c, comp} -> [c, comp] end)]
      end
    end
  end

  defp selector_list do
    gen all(complexes <- list_of(complex(), min_length: 1, max_length: 3)) do
      complexes
    end
  end

  property "parse(to_string(ast)) == ast" do
    check all(ast <- selector_list(), max_runs: 1000) do
      assert DOM.CSS.parse(DOM.CSS.to_string(ast)) == ast
    end
  end

  property "to_string is idempotent through a parse round-trip" do
    check all(ast <- selector_list(), max_runs: 1000) do
      serialized = DOM.CSS.to_string(ast)
      assert DOM.CSS.to_string(DOM.CSS.parse(serialized)) == serialized
    end
  end
end
