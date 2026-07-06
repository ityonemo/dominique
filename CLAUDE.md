# Dominique — Claude Guide

An Elixir implementation of the browser **DOM**. A DOM is a `GenServer` owning a
private ETS table of `NodeData`; the public node structs
(`DOM.Node.Element`, `Text`, `Comment`, `Document`, `DocumentFragment`,
`DocumentType`) are immutable **handles** (`%{server, id}`) into that server, not
live objects. `DOM.Node` is a Protoss protocol implemented by every node type.

Key semantic (see `README.md`): appending a node owned by another DOM transfers
its whole subtree across servers, so old handles go **stale**. Callers must use
the handle returned by `DOM.Node.append_child/2` after a cross-document transfer.

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
- Cross-module internal APIs are `_`-prefixed; owner modules forward via
  `DOM._node_*`; app callers use the owning module's public API.
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

## Before finishing any change

Run `mix format` (config in `.formatter.exs`), then `mix test`, and report the
RED/GREEN results with a link to the test.
