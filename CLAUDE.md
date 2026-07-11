# Dominique — Claude Guide

An Elixir implementation of the browser **DOM**. A DOM is a `GenServer` owning a
private ETS table of per-type `DOM.NodeData.*` records. A node **handle** is the
single struct `%DOM.Node{server, node_id, type}` — an immutable reference into that
server (server pid, node id, and node-kind atom `:element | :text | :comment |
:document | :document_fragment | :document_type`), not a live object.

Key semantic (see `README.md`): appending a node owned by another DOM transfers
its whole subtree across servers, so old handles go **stale**. Callers must use
the handle returned by `DOM.Node.append_child/2` after a cross-document transfer.

## Two struct layers — handle vs storage

- **`DOM.Node` is the ONE user-facing handle struct** (`%{server, node_id, type}`).
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
- **Every `handle_call` threads `from` into its `*_impl`** as the second-to-last
  arg (before `state`), even when discarded (`_from`). This keeps impl headers
  deterministic: refactoring an impl to defer its reply (`GenServer.reply(from,
  …)` + `{:noreply, state}`) stays local to the impl body — the router never
  changes. `handle_info`/`handle_continue` impls have no `from`.
- Drive the ETS table from `DOM.Node`/`DOM.Element` via the generic bridges
  `DOM._select` / `_select_replace` (send a `defmatchspecp` spec, built in the
  caller) and `DOM._atomic_ets_op(server, fn nodes -> … end)` (a multi-step
  read-modify-write run atomically in one message). Prefer these over a new
  bespoke `_node_*`/`_element_*` bridge for row-local reads/writes; keep a bespoke
  bridge only for ops needing server context (e.g. `document_id`) or tree work.
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
selector struct and runs inside the DOM GenServer against the ETS table (helpers
in `lib/dom/css/_query.ex`, `DOM.CSS.Query`).

The **full Level-4 grammar parses and matches** for everything derivable from the
tree. Implemented: type/universal/id/class; attribute (all 6 operators + `i`/`s`
flags); compound + all 4 combinators; selector lists; `:not`/`:is`/`:where`/`:has`;
`:root`/`:empty`; `:first/last/only-child`, `:nth-*child(An+B [of S])`; the
`*-of-type` family; `:lang`/`:dir(ltr|rtl)` (inherited via the ancestor walk);
`:scope` (bound to the query root in `lib/dom.ex`; `DOM.CSS.bind_scope/2`); the
shadow selectors `:host`/`:host()`/`:host-context()`/`::slotted()` (see the Shadow
DOM section below).

**Namespaces** (query context, no declared prefixes): a **string** prefix
(`svg|rect`) raises `ArgumentError` — parse + `DOM.CSS.validate!/1` run in the
CALLER's process (`DOM.query_selector*`/`matches`), so the document server never
crashes on a bad selector. `*|`/bare match any namespace; `|` (`:none`, the null
namespace) matches nothing, since every parsed element is `:html`/`:svg`/`:mathml`.

**Attribute namespaces (`DOM.Namespace`).** An attribute is `{key, value}` where the
KEY is a plain qualified-name **string** (the 99% case, unchanged) OR a `{prefix,
local, url}` **triple** for a namespaced attribute; the value is always a plain
string. Plain attributes keep bare-string keys, so all value readers, the `:id`/
`:class`/`:attr` index, and CSS attribute matching are untouched (CSS matches
string-keyed attrs only and correctly ignores triples). `DOM.NodeData.Element`
carries the key helpers: `qualified_name/1` (DOM colon form, used by the serializer
+ `getAttributeNames`), `dat_name/1` (html5lib **space** form `xlink href`, used by
`test/_support/dat_outline.ex` so the tree-construction suite still passes),
`matches_key?/2`. The parser's foreign-content adjustment builds triples via
`DOM.Namespace` (the closed element-ns + xlink/xml/xmlns tables). API:
`DOM.create_element_ns`, `Element.get_attribute_ns`/`set_attribute_ns` (identity =
`(url, local)`; overwrite KEEPS the old prefix per WHATWG; same-prefix-different-url
are two attributes), `lookup_prefix`/`lookup_namespace_uri` (nil in HTML docs —
`xmlns:*` is a plain attribute there, matching both browsers).

**Implemented — derivable UI/state pseudo-classes** (element name + attributes +
ancestry, no runtime state; `DOM.CSS.PseudoClass` + `DOM.CSS.Query`): `:enabled`/
`:disabled` (own `disabled`, `fieldset[disabled]` inheritance with the first-
`<legend>` exception, `optgroup[disabled]` for options), `:required`/`:optional`,
`:checked` (the `checked`/`selected` attribute), `:default` (checked input /
selected option / **the form's first submit-capable control**), `:link` (`a`/`area`
with `href`), `:read-write`/`:read-only` (**contenteditable inherited via the
ancestor walk**, honoring `contenteditable=false`). Verified against the
Chromium+Firefox oracle (`query_selector_test.exs`, `derivable_pseudo_test.exs`).

**Deferred — intended to be implemented:**

- **`:dir(auto)`** — needs bidi resolution of element text, which `NodeData` does
  not model; stays match-nothing.
- **Interaction/navigation-state pseudo-classes** — `:hover`, `:focus`, `:active`,
  `:focus-visible`, `:focus-within`, user-toggled `:checked`, `:indeterminate`,
  `:valid`, `:visited`, `:target`, `:current`, … These depend on input/focus
  state, HTML element state machines, or navigation/history — **none of which
  `NodeData` models today**. **We DO want to support these**, which will require
  modeling that state (an input/focus model, HTML element interfaces, a
  navigation/URL model — downstream of Events / a state layer). Until then they
  are unmatchable.
- **Policy for unmodelable pseudo-classes** (decide when building `match/3`):
  prefer **match-nothing** over raising — that mirrors browser `querySelector`,
  where e.g. `:hover` simply returns no elements rather than erroring.

## Shadow DOM (structural, Event-free)

A **ShadowRoot is a detached root tree** (`DOM.NodeData.ShadowRoot`: `host`, `mode`,
+ extent fields — `parent: nil`, own extent window, `root == self`) hosted by an
element, modeled on template `content`. `nodeType` 11 / `nodeName`
`"#document-fragment"`; only `type/1` (`:shadow_root`) distinguishes it from a
fragment. The host element carries a `shadow_root` field (parallel to `content`).
Because the serializer reads `children_by_extent` and never `shadow_root`, the host's
`outerHTML` **excludes the shadow tree for free**; scoped `query_selector(shadow, …)`
scopes to the shadow subtree for free via `descendant_ids`.

- **`Element.attach_shadow(el, mode)`** / **`Element.shadow_root(el)`** (closed → nil);
  attach-twice or a non-host element raises `DOM.NotSupportedError`. Host eligibility
  = the HTML host-name list + hyphenated custom-element names.
- **`DOM.ShadowRoot`** — `inner_html`/`set_inner_html` (reuses the fragment path),
  `host`, `mode`. **`DOM.Slot`** — `assigned_nodes`/`assigned_elements`.
  **`DOM.Node.get_root_node(node, composed? \\ false)`** (composed jumps shadow→host
  across nested boundaries) and **`DOM.Node.assigned_slot(node)`**.
- **Slot assignment is MAINTAINED on mutation** (`DOM.NodeData.Slots`, file
  `lib/dom/node_data/_slots.ex`), stored as `:slot`/`:assigned`/`:assigned_host` index
  rows (the established row-family pattern), recomputed at append/insert/remove/
  `set_attribute`/`set_inner_html`/`attach_shadow` for the affected host, and verified
  by `check_slots!` in `check_consistency!`. First slot per name wins, host light-tree
  order; unassigned ⇒ `[]` (fallback content is not "assigned"). This is where
  `slotchange` would fire — we recompute silently (no event).
- **Shadow CSS.** The CSS `context` carries `scope_host` (nil outside a shadow scope).
  `:host`/`:host()`/`:host-context()` match the host (host-context crosses into the
  light tree via the ancestor walk); combinators cross the shadow boundary via
  `Query.shadow_parent`/`shadow_ancestors` so `:host p` reaches the shadow tree.
  **Browser-faithful query boundaries (verified against the oracle):** a shadow-scoped
  `querySelectorAll` returns ONLY the shadow root's descendants — the host and slotted
  light-DOM nodes are never candidates. `:host`/`:host()` therefore return nothing from
  `querySelectorAll` (only interrogable via `matches/2`); `::slotted(…)` matches nothing
  through the DOM query APIs at all (a pseudo-element, like `::before`) — it only needs
  to *parse*. `:host-context()` is Chromium-only (Firefox throws), so it is unit-tested
  via `matches/2`, not against the browser oracle.

**Events (implemented — light DOM + shadow):** the event system is built.
`DOM.Node.add_event_listener`/`remove_event_listener`/`dispatch_event`,
`DOM.Event` (`new/2`, `prevent_default`, `stop_propagation`,
`stop_immediate_propagation`), full capture→target→bubble propagation with
`eventPhase`/`bubbles`/`cancelable`, `{capture, once, passive}`, and shadow
**retargeting + composed path** (`composed_path/2`). Listeners are lambdas stored
as `:listener` index rows (reachable in-server during dispatch via the re-entrancy
fork); an in-flight event's mutable state lives in a ref-keyed `:active_event` row
(so nested/re-entrant dispatch coexist). Dispatch runs in `DOM.Events`
(`lib/dom/_events.ex`). Verified against the Chromium+Firefox oracle
(`test/integration/event_test.exs`).

**Deferred (need a microtask/event-loop model):** `slotchange` is dispatched
**asynchronously as a microtask** (verified against both browsers — it fires *after*
the mutation, not during), so it is blocked on a scheduling layer Dominique does not
model yet. The same layer is the natural home for `MutationObserver` and
custom-element reactions. Also still deferred: imperative `slot.assign()`
(manual slotting), and default actions / interaction & navigation state (`:hover`,
`:focus`, form submission, checkbox toggle, `preventDefault` actually suppressing
anything — `preventDefault` currently only sets the flag `dispatchEvent` returns).

## Before finishing any change

Run `mix format` (config in `.formatter.exs`), then `mix test`, and report the
RED/GREEN results with a link to the test.
