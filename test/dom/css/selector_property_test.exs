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
              gen(all(ns <- namespace(), do: {:ns_presence, ns})),
              tuple({attr_op(), ident()}),
              tuple({attr_op(), ident(), member_of([:i, :s])})
            ])
        ) do
      case shape do
        :presence -> {:attr, name}
        {:ns_presence, ns} -> {:attr, {ns, name}}
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
    one_of([
      gen all(
            name <-
              member_of(["nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type"]),
            ab <- anb()
          ) do
        {:pseudo_class, name, ab}
      end,
      gen all(
            name <- member_of(["nth-child", "nth-last-child"]),
            ab <- anb(),
            list <- compound_list()
          ) do
        {:pseudo_class, name, ab, list}
      end
    ])
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
      functional_selector_pc(),
      functional_args_pc(),
      gen(all(n <- ident(), do: {:pseudo_element, n}))
    ])
  end

  # An optional namespace prefix: a name, :any (*), or :none (|).
  defp namespace, do: one_of([ident(), constant(:any), constant(:none)])

  # A compound: an optional leading type-or-universal (optionally namespaced),
  # then zero+ subclasses, but never empty.
  defp compound do
    gen all(
          lead <-
            one_of([
              constant([]),
              gen(all(n <- ident(), do: [{:type, n}])),
              gen(all(n <- ident(), ns <- namespace(), do: [{:type, n, ns}])),
              constant([:universal]),
              gen(all(ns <- namespace(), do: [{:universal, ns}]))
            ]),
          subs <- list_of(subclass(), max_length: 3),
          simples = lead ++ subs,
          simples != []
        ) do
      {:compound, simples}
    end
  end

  defp functional_selector_pc do
    one_of([
      gen all(name <- member_of(["is", "where"]), list <- compound_list()) do
        {:pseudo_class, name, {:selector_list, list}}
      end,
      gen all(list <- relative_list()) do
        {:pseudo_class, "has", {:selector_list, list}}
      end
    ])
  end

  # Relative complex selectors (used by :has): each may lead with a combinator.
  defp relative_list do
    gen all(relatives <- list_of(relative_complex(), min_length: 1, max_length: 2)) do
      relatives
    end
  end

  defp relative_complex do
    lead_combinator = member_of([:child, :next_sibling, :subsequent_sibling])

    gen all(lead <- one_of([constant(nil), lead_combinator]), comp <- compound()) do
      if lead, do: [lead, comp], else: comp
    end
  end

  defp functional_args_pc do
    gen all(
          name <- member_of(["lang", "dir"]),
          args <- list_of(ident(), min_length: 1, max_length: 3)
        ) do
      {:pseudo_class, name, {:args, args}}
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
