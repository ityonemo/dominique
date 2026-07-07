# Dominique — Claude Guide

An Elixir implementation of the browser **DOM**. A DOM is a `GenServer` owning a
private ETS table of `NodeData`; the public node structs
(`DOM.Node.Element`, `Text`, `Comment`, `Document`, `DocumentFragment`,
`DocumentType`) are immutable **handles** (`%{server, id}`) into that server, not
live objects. `DOM.Node` is a Protoss protocol implemented by every node type.

Key semantic (see `README.md`): appending a node owned by another DOM transfers
its whole subtree across servers, so old handles go **stale**. Callers must use
the handle returned by `DOM.Node.append_child/2` after a cross-document transfer.

## Architecture & dispatch conventions

**Where a new operation lives — `Node` vs `DOM`.** Follow the Elixir "first
argument owns the function" convention:

- **Node-first operations go on the `DOM.Node` protocol.** If a DOM node is the
  natural first argument, add it to `DOM.Node` and dispatch on the handle:
  `Node.append_child(parent, child)`, `Node.next_sibling(node)`,
  `Node.remove_child(parent, child)`.
- **Document-scoped operations go on `DOM`.** `DOM` is the **context module** for
  the `DOM.Node.Document` type — EXCLUDING Document's `DOM.Node` protocol
  implementations, which must live in `DOM.Node.Document`. When the operation
  conceptually belongs to the document and it is more convenient for the first
  argument to be the **DOM object itself** rather than the document node, put it
  on `DOM`: `DOM.new()`, `DOM.create_element(document, "div")`, and future
  document-level queries like `get_element_by_id`, `create_element_ns`.

**Three call layers (the `_` prefix).** A node handle is opaque data; the owning
node module forwards through the `DOM` server. Every operation flows:

```
app code   →  Node.local_name(el)          # public API (context module / protocol)
           →  DOM._element_local_name(...)  # _-prefixed internal cross-module bridge
           →  GenServer.call → local_name_impl/2   # defp, the real logic
```

- **Public (no underscore):** the user-facing surface — `DOM.new/2`,
  `DOM.create_*`, and the `DOM.Node` protocol functions on handles.
- **Internal (`_`-prefixed), e.g. `DOM._node_append_child/3`,
  `DOM._element_local_name/2`, `DOM._export_subtree/2`:** public *only* because a
  different module (the node module) must reach into `DOM` across a module
  boundary, so they cannot be `defp`. Treat them as private; application code
  must not call them. `_export_subtree`/`_remove_subtree` are the cross-server
  primitives used to move a subtree between two DOM GenServers during adoption.
- **`defp *_impl`:** the actual behavior behind each `handle_call`, per
  ROUTER_PATTERN.md.

Name internal bridges `_node_*` when they back a `DOM.Node` protocol function;
use a type-specific prefix (e.g. `_element_local_name`) when the public function
is type-specific.

**Protoss `after` block.** `DOM.Node` is a Protoss `defprotocol`, which supports
an `after` block that runs after the protocol/impl definitions. Use it
**strategically** to define shared, node-type-independent operations once instead
of copying them into all six impls — e.g. operations derivable purely from other
protocol callbacks (`next_sibling`/`previous_sibling` from `parent_node/1` +
`child_nodes/1`), or a shared leaf-rejection helper. Dispatch that genuinely
differs per node type still belongs in each module's impl clause; do not use the
`after` block to flatten real per-type differences.

## The two guideline documents

The complete guidelines live in `.claude/docs/` (copied verbatim from the repo
root `AGENTS.md` / `ROUTER_PATTERN.md`). **Read them before writing code:**

- **`.claude/docs/AGENTS.md`** — feature workflow, testing, Elixir style, ETS specs.
- **`.claude/docs/ROUTER_PATTERN.md`** — the mandatory GenServer structure.

The rules below are the load-bearing summary; the docs are authoritative.

## GenServer Router Pattern (mandatory for every GenServer-like module)

Module order: (1) Lifecycle/`init`, (2) API declarations (specs only, grouped),
(3) Implementations, (4) Helpers, (5) Router at the bottom.

- Router clauses **only** pattern-match, extract params, and delegate to a
  private `*_impl` function — no business logic, I/O, branching, or state
  transitions in the router.
- Each public API function sits immediately before its `*_impl`. `*_impl`
  functions hold the logic and return the full OTP callback tuple.
- Group all public types/specs in one API section (spec dislocation). Add an
  `*_impl` spec only for private handlers (`info`/`continue`) with no public API.
- Default to `GenServer.call/3` (even for `:ok`-only commands); use `cast` only
  when removing backpressure is deliberate. `handle_info/2` only for protocols
  defined outside the public API (timers, monitors, task replies).
- No defensive catch-all clauses to swallow unexpected messages.

## Feature Development — test-first, RED → GREEN (never skip)

1. Write the focused test first.
2. Run it and **show RED** — it must fail for the missing behavior, not a
   compile/setup/infra error.
3. Implement the feature.
4. Run the same test and **show GREEN**.
5. Run the broader suite to check regressions.

Never claim a feature is done without showing both RED and GREEN. In the final
handoff, include a clickable link to the feature's test.

Two test layers:
- **Unit** (`test/dom/…`) — implementation invariants of each public function.
- **Integration** (`test/integration/…`) — browser-observable scenarios run as
  real JS in Chromium **and** Firefox via the persistent Playwright oracle
  (`test/_support/playwright.ex`); the Elixir result must match the browser
  consensus. Don't mirror browser traces one-for-one at the unit level. If an
  integration feature has no meaningful unit invariant, document why.

All test modules `use ExUnit.Case, async: true` and must be safe under
concurrency — no serializing around shared state, fixed names, or infra races.
In a `playwright` block, declare `@link` once; later tests inherit it. A
different link usually means the tests belong in another module.

Use `assert value` / `refute value` for boolean and nil checks, not comparisons
with `true`/`false`/`nil`.

## Running tests

```bash
mix test                       # local: Chromium + Firefox run concurrently
```

Do **not** run separate per-browser commands locally. `PLAYWRIGHT_BROWSER=chromium`
and `PLAYWRIGHT_BROWSER=firefox` are only for isolated CI jobs or debugging.
Playwright must be installed in the npx cache:
`npx --yes playwright@latest install chromium firefox`.

## Elixir style (see AGENTS.md for the full list)

- Simplest control flow that fits: `if` over `case` over `cond`; `case` only for
  meaningful pattern matching, not verbose nil/boolean checks.
- `if value = lookup(), do: ...` for nil/truthiness. No `unless` — use
  `if !cond` / `if not cond`. In `cond`, use `:else` for the catch-all.
- No side-effect-only `_ <- expr` in `with`; put the side effect in the chain.
- `Map.get(map, key, default)` over `map[key] || default`.
- `alias`/`require` at the module head after `use`.
- Cross-module internal APIs are `_`-prefixed; context modules forward via
  `DOM._node_*`; app callers use the context module's public API.
- No defensive guards duplicating specs/trusted contracts. `tap/2` only inside a
  pipeline that must forward the original value. Keep it simple, fail fast.
- Naming: `get` → value | `nil`; `fetch` → `{:ok, v} | {:error, reason}`;
  `fetch!` → value or raises.

## ETS match specifications

Use the `match_spec` library — `defmatchspec`/`defmatchspecp` after
`use MatchSpec`; `MatchSpec.fun2ms/1` only for local one-offs. Pin args with
`fun2msfun/4`/`defmatchspec`/`defmatchspecp`. Test non-trivial specs with
`:ets.test_ms/2` **and** through the ETS operation that uses them. Never hand-build
match-spec tuples.

## CSS selector engine (`DOM.CSS`)

`DOM.CSS` is a Protoss protocol. The parser (`DOM.CSS.Parser`, generated by
Pegasus from `lib/dom/css/selector.peg`) turns a selector string into a struct
AST (`DOM.CSS.Type`, `Compound`, `Complex`, `PseudoClass`, …); `to_string/1`
serializes it back (round-trip + idempotence are StreamData-property-tested). The
protocol callback `match(selector, nodes, candidate_ids)` dispatches on the
selector struct and is meant to run inside the DOM GenServer against the ETS
table — currently every impl is stubbed `raise "unimplemented"`.

The **full Level-4 grammar parses**, but `match/3` support is being filled in
tiers. The parser is complete; matching is not.

**Deferred — intended to be implemented:**

- **Structural pseudo-classes** (first matcher arc): `:first-child`,
  `:last-child`, `:only-child`, `:nth-*(An+B [of S])`, `:empty`, `:root`,
  `:not`, `:is`, `:where`, `:has`. Fully derivable from the tree.
- **`:lang` / `:dir`** — implementable from the `lang`/`dir` attribute + the
  ancestor walk we already have (`:dir` also needs bidi rules). Deferred as
  scope, not impossibility. **We do want these.**
- **UI / state / navigation pseudo-classes** — `:hover`, `:focus`, `:active`,
  `:focus-visible`, `:focus-within`, `:checked`, `:disabled`, `:enabled`,
  `:required`, `:valid`, `:indeterminate`, `:read-only`, `:visited`, `:link`,
  `:target`, `:current`, … These depend on input/focus state, HTML element
  semantics + their state machines, or navigation/history — **none of which
  `NodeData` models today**. **We DO want to support these**, which will require
  modeling that state (an input/focus model, HTML element interfaces, a
  navigation/URL model). Until then they are unmatchable.
- **Policy for unmodelable pseudo-classes** (decide when building `match/3`):
  prefer **match-nothing** over raising — that mirrors browser `querySelector`,
  where e.g. `:hover` simply returns no elements rather than erroring.

## Before finishing any change

Run `mix format` (config in `.formatter.exs`), then `mix test`, and report the
RED/GREEN results with a link to the test.
