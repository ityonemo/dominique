---
description: Develop a DOM feature test-first, enforcing the RED → GREEN workflow
---

Implement the feature described in `$ARGUMENTS` following this repo's guidelines.

Read `.claude/docs/AGENTS.md` and `.claude/docs/ROUTER_PATTERN.md` first if you
have not already this session.

Follow the mandatory RED → GREEN workflow, and do not skip any step:

1. Decide the test layer(s): a unit test in `test/dom/…` for the implementation
   invariant, and/or an integration test in `test/integration/…` with a
   `playwright` block and `@link` to the relevant WPT scenario. If an
   integration feature has no meaningful unit invariant, say so and explain why.
2. Write the focused test(s) first. Use `async: true`; design for concurrency.
3. Run the test and **show RED** — confirm it fails for the missing behavior,
   not a compile/setup error.
4. Implement the feature. For GenServer changes, keep OTP callbacks as thin
   routers delegating to `*_impl` functions per ROUTER_PATTERN.md.
5. Run the same test and **show GREEN**.
6. Run the broader suite (`mix test`) to check for regressions.
7. Run `mix format`.

In your final handoff, include a clickable link to the feature's test and show
both the RED and GREEN results. Do not claim the feature is done without them.
