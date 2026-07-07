# Dominique — Claude Guide

An Elixir implementation of the browser **DOM**. A DOM is a `GenServer` owning a
private ETS table of per-type `DOM.NodeData.*` records. A node **handle** is the
single struct `%DOM.Node{server, id, type}` — an immutable reference into that
server (server pid, node id, and node-kind atom `:element | :text | :comment |
:document | :document_fragment | :document_type`), not a live object.

Key semantic (see `README.md`): appending a node owned by another DOM transfers
its whole subtree across servers, so old handles go **stale**. Callers must use
the handle returned by `DOM.Node.append_child/2` after a cross-document transfer.

## Two struct layers — handle vs storage

- **`DOM.Node` is the ONE user-facing handle struct** (`%{server, id, type}`).
  Never a protocol; operations are `type`-guarded function clauses. Never expose
  a `NodeData` record to callers.
- **`DOM.NodeData` is a Protoss protocol** implemented by the six per-type
  records stored in the ETS tuple space: `DOM.NodeData.Element{local_name,
  attributes, parent, children}`, `.Text{value, parent}`, `.Comment{value,
  parent}`, `.Document{children}`, `.DocumentFragment{children}`,
  `.DocumentType{name, public_id, system_id, parent}`. Heterogeneous, no dead
  fields. The protocol carries per-kind values (`type/1` → the handle atom,
  `node_type/1` → the DOM number, `node_name/1`); the `after` block has the
  struct-agnostic `parent/1`/`children/1`. Reads that ETS match specs express are
  **map patterns keyed on `__struct__`** (subset matching, so no field
  wildcarding) — see `lib/dom/css/_query.ex`.

## Dispatch conventions — where a new operation lives

Partition by **scope** (Elixir "first argument owns the function"):

- **Generic node operations → `DOM.Node`.** Apply to any node kind:
  `Node.append_child(parent, child)`, `Node.child_nodes(node)`,
  `Node.next_sibling(node)`, `Node.node_type/node_name/value/text_content`,
  `Node.clone_node/2`. Fail-fast `type`-guard clauses live here (e.g. appending
  to a `:text` node raises without a server round-trip).
- **Element-intrinsic operations → `DOM.Element`.** Apply only to elements:
  `Element.local_name/1` and the attribute API (`get_attribute`, `set_attribute`,
  `has_attribute`, `remove_attribute`, `get_attribute_names`). Each is guarded on
  `%DOM.Node{type: :element}`, so calling it on a non-element fails fast.
- **Whole-document / query operations → `DOM`.** `DOM` is the **context module**
  and the GenServer. Node creation (`DOM.new`, `DOM.create_element(document,
  "div")`, `create_*`) and tree queries that take any node as scope
  (`get_element_by_id`, `get_elements_by_tag_name`, `query_selector`,
  `query_selector_all`, `matches`) live here.

**Three call layers (the `_` prefix).** A handle is opaque data; `DOM.Node` /
`DOM.Element` forward through the `DOM` server. Every operation flows:

```
app code   →  Element.local_name(el)        # public API (scoped module)
           →  DOM._element_local_name(...)   # _-prefixed internal cross-module bridge
           →  GenServer.call → local_name_impl/2   # defp, the real logic
```

- **Public (no underscore):** the user-facing surface — `DOM.*`, `DOM.Node.*`,
  `DOM.Element.*`.
- **Internal (`_`-prefixed), e.g. `DOM._node_append_child/3`,
  `DOM._element_local_name/2`, `DOM._export_subtree/2`:** public *only* because
  `DOM.Node`/`DOM.Element` must reach into `DOM` across a module boundary, so they
  cannot be `defp`. Treat them as private. `_export_subtree`/`_remove_subtree` are
  the cross-server primitives used to move a subtree between DOM GenServers during
  adoption.
- **`defp *_impl`:** the actual behavior behind each `handle_call`.

Name bridges `_node_*` when they back a `DOM.Node` function; `_element_*` when
they back a `DOM.Element` function. A single-caller bridge is a middleman: only
keep a `_`-prefixed bridge when a *foreign* module actually needs it (a `DOM`
public function calling its own bridge is a self-call, not a second caller) —
otherwise inline the `GenServer.call`.

## File-naming convention

In a directory populated by one-struct-per-file modules, a support module that
has **no associated struct** gets a `_`-prefixed **filename** (not module name),
which pins it to the top of the listing. Precedent: `lib/dom/css/_parser.ex`
(`DOM.CSS.Parser`), `lib/dom/css/_query.ex` (`DOM.CSS.Query`). Struct modules keep
plain filenames (`type.ex`, `class.ex`, `lib/dom/node_data/element.ex`).

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

**Match a MAP pattern, not a struct pattern, for subset matching.** A struct
pattern (`%NodeData.Element{local_name: ^n}`) pins every *unmentioned* field to
its default, so it fails to match real rows and forces verbose `field: _`
wildcards. A map pattern keyed on `__struct__` (`%{__struct__: NodeData.Element,
local_name: ^n}`) does **subset** matching — only the named keys are constrained,
extra keys ignored — so it matches per-type structs cleanly with no wildcards.
`defmatchspecp` accepts map patterns (verified). See `lib/dom/css/_query.ex`.

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
