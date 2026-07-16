# Dominique

An Elixir implementation of the browser **DOM**. A document is a `GenServer` that
owns a private ETS table of per-type node records; you manipulate it through
immutable **handles** (`%DOM.Node{server, node_id, type}`) rather than live objects.
It exists to **test DOM interactions from Elixir** — the tree, CSS selectors, events,
and the WHATWG event loop — without a browser, with behavior verified against real
Chromium and Firefox.

```elixir
doc = DOM.new("<ul id='list'><li class='item'>a</li><li class='item'>b</li></ul>")

DOM.query_selector_all(doc, "#list > .item")   # [%DOM.Node{}, %DOM.Node{}]
item = DOM.query_selector(doc, "li.item")
DOM.Element.get_attribute(item, "class")       # "item"

DOM.Node.add_event_listener(item, "click", fn _event -> IO.puts("clicked") end)
DOM.Node.dispatch_event(item, DOM.Event.new("click", bubbles: true))
```

## Architecture

- **Two struct layers.** `DOM.Node` is the one user-facing handle — a struct carrying
  `{server, node_id, type}`, never a live object. Internally, six per-type
  `DOM.NodeData.*` records live in the server's ETS tuple space. Operations are
  `type`-guarded function clauses on the handle, never a protocol over the handle.
- **Scoped dispatch.** Generic node operations → `DOM.Node`; element-intrinsic ones
  (attributes, `local_name`) → `DOM.Element`; whole-document / query operations →
  `DOM` (which is also the GenServer). `querySelector` is scoped per `ParentNode`
  kind (`DOM`, `Element`, `DocumentFragment`, `ShadowRoot`).
- **Nested-set tree.** Child order and containment are encoded in binary extent keys
  in an `:ordered_set` index, so `querySelectorAll`, ancestor/containment tests, and
  `compareDocumentPosition` are index range scans, not tree walks.

## What's implemented

- **Tree & attributes** — the everyday node/element surface, the attribute API
  (including namespaced attributes and live `Attr` nodes), `cloneNode`, cross-document
  adoption.
- **CSS selectors** — the full CSS Level-4 grammar parses and matches for everything
  derivable from the tree (type/id/class/attribute, all combinators, selector lists,
  `:not`/`:is`/`:where`/`:has`, the structural and `*-of-type` families, and the
  derivable UI/form-state pseudo-classes). The combinator engine is index-fused (no
  per-candidate re-query).
- **Shadow DOM** — shadow roots, maintained slot assignment, shadow-scoped CSS.
- **Events & the event loop** — full capture→target→bubble dispatch with shadow
  retargeting; microtasks, `MutationObserver`, `slotchange`, timers
  (`setTimeout`/`setInterval`); custom elements with synchronous reactions;
  `AbortController`/`AbortSignal`; focus and other interaction state.
- **Ranges & traversal** — `Range`, `TreeWalker`, `NodeIterator`.

Everything browser-observable is checked against a Chromium+Firefox oracle via
Playwright, and every document verifies an internal consistency invariant on teardown.

## Node handle freshness

Node structs are immutable handles into a DOM GenServer, not live JavaScript
objects. Like structs returned from a GenServer or database, a node handle may
become stale after ownership changes.

Appending a node owned by another DOM transfers its entire subtree from the
source DOM server to the destination DOM server. `DOM.Node.append_child/2`
returns a current handle owned by the destination server. Callers must use that
returned handle after a cross-document transfer:

```elixir
child = DOM.Node.append_child(destination_parent, child)
```

Handles retained from before the transfer still point at the source server and
must be considered stale. This intentionally differs from JavaScript, where
object identity remains live across document adoption.

## Microtasks and error handling

DOM operations that defer work — `slotchange`, and later `MutationObserver` and
custom-element reactions — enqueue **microtasks** that run at a checkpoint after
the current operation, matching the WHATWG event loop. The checkpoint drains the
queue inside the document server.

**A microtask that raises crashes the document server.** This is deliberate and
differs from a browser, which reports the error and continues to the next
microtask. WHATWG does not require isolation here, and Dominique's purpose is to
**test DOM interactions from Elixir** — so a lambda that raises is a bug in *your*
code, and letting it take down the document is a correct forcing function for
correctness (and idiomatic OTP "let it crash"). Do not wrap microtask execution
in a `try` to swallow this: a supervised document that silently survives a broken
listener would hide exactly the defects this library exists to surface.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `dominique` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dominique, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/dominique>.
