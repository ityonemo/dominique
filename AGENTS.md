# Agent Guidelines

All GenServers and GenServer-like modules in this repository must follow the
[GenServer Router Pattern](ROUTER_PATTERN.md).

Read that document before creating or modifying a GenServer. In particular,
keep OTP callback clauses as thin routers, group the complete public API in one
cohesive section, keep business logic in private `_impl` functions, and default
public API traffic to `GenServer.call/3`.

## Feature Development

Develop every feature test-first:

1. Write the focused test before writing the implementation.
2. Link the test when introducing or reporting work on the feature.
3. Run the test and show RED: it must fail for the expected missing behavior,
   not because of an unrelated compilation, setup, or infrastructure error.
4. Implement the feature.
5. Run the same test and show GREEN.
6. Run the relevant broader suite to check for regressions.

Do not claim a feature is implemented without showing both its RED and GREEN
test results. In the final handoff, include a clickable link to the feature's
test.

Each public function should normally have focused unit coverage for its
invariants. Integration tests cover browser-observable scenarios; unit tests
cover the smaller implementation contracts that support those scenarios.
Several integration scenarios may be supported by one unit test, and unit
tests should not duplicate browser traces one-for-one. Develop both layers with
the same RED-to-GREEN workflow. If an integration feature has no meaningful
unit-level invariant, document why.

All ExUnit test modules must use `async: true`. Tests and support code must be
designed for concurrent execution; do not serialize the suite to work around
shared mutable state, fixed resource names, or test-infrastructure races.

Within a `playwright` block, declare `@link` once and let subsequent tests
inherit it. A different source link usually indicates that the tests belong in
a different integration module, although the DSL permits updating `@link`.

For local verification, run the suite once with `PLAYWRIGHT_BROWSER` unset;
Playwright executes Chromium and Firefox concurrently by default. Do not run
separate browser commands locally. `PLAYWRIGHT_BROWSER=chromium` and
`PLAYWRIGHT_BROWSER=firefox` are for isolated CI jobs or explicit debugging.

## Elixir Code Style

Prefer the least complicated control-flow form that expresses the behavior:
`if` over `case`, and `case` over `cond`. Use `case` for meaningful pattern
matching, not as a verbose nil or boolean check.

- For nil/truthiness checks, prefer assignment in `if`, such as
  `if value = lookup(), do: use(value)`.
- Do not use `unless`; use `if !condition` or `if not condition`.
- In `cond`, use `:else` rather than `true` for the catch-all branch.
- Do not use `_ <- expression` in `with` merely to run a side effect; place the
  side-effecting expression directly in the chain.
- Prefer `Map.get(map, key, default)` over `map[key] || default`.
- Put `alias` and `require` declarations at the head of the module after
  `use`.
- Prefix cross-module functions that exist only as an internal/private API
  with `_`. Public owner modules should forward through functions such as
  `DOM._node_*`; application callers should use the owning module's public API.
- Do not add defensive type guards that duplicate specs or trusted internal
  contracts. Use guards only when they select a meaningful algorithm clause.
- Use `tap/2` only within a pipeline whose original value must continue to the
  next stage. For standalone side effects, call the function directly.
- Keep code simple and fail fast. Do not add defensive catch-alls or
  abstractions without a concrete need.
- Retrieval naming: `get` returns a value or `nil`, `fetch` returns an
  `{:ok, value} | {:error, reason}` tuple, and `fetch!` returns a value or
  raises.

In tests, use `assert value` and `refute value` for boolean and nil checks
rather than comparisons with `true`, `false`, or `nil`.

## ETS Match Specifications

Use the `match_spec` library whenever writing ETS match specifications. Prefer
`defmatchspec` and `defmatchspecp` after `use MatchSpec`. Use
`MatchSpec.fun2ms/1` only for genuinely local, one-off specifications. Do not
manually construct match-spec tuples.

Use parameterized match specs with pinned arguments through
`MatchSpec.fun2msfun/4`, `defmatchspec`, or `defmatchspecp`. Test non-trivial
specifications with `:ets.test_ms/2` as well as through the ETS operation that
uses them.
