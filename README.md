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

## API index — WHATWG member → Dominique

Dominique does **not** put every DOM method on one module; each WHATWG interface maps
to a scope module, and members are partitioned by which interface they belong to. This
index maps the JS member to its Elixir equivalent. All functions take a `%DOM.Node{}`
handle (or another handle struct) as their first argument.

### `Document` → `DOM`

| WHATWG | Dominique |
|---|---|
| `new Document()` / parse | `DOM.new/0,1` |
| `documentElement` | `DOM.document_element/1` |
| `body` / `head` | `DOM.body/1` / `DOM.head/1` |
| `createElement` | `DOM.create_element/2` |
| `createElementNS` | `DOM.create_element_ns/3` |
| `createTextNode` | `DOM.create_text_node/2` |
| `createComment` | `DOM.create_comment/2` |
| `createDocumentFragment` | `DOM.create_document_fragment/1` |
| `createAttribute` | `DOM.create_attribute/2` |
| `implementation.createDocumentType` | `DOM.create_document_type/4` |
| `getElementById` | `DOM.get_element_by_id/2` |
| `getElementsByClassName` | `DOM.get_elements_by_class_name/2` |
| `getElementsByTagName` | `DOM.get_elements_by_tag_name/2` |
| `getElementsByName` | `DOM.get_elements_by_name/2` |
| `querySelector` / `All` | `DOM.query_selector/2` / `DOM.query_selector_all/2` |
| `adoptNode` / `importNode` | `DOM.adopt_node/2` / `DOM.import_node/2,3` |
| `activeElement` | `DOM.active_element/1` |
| `createRange` | `DOM.Range.create_range/1` |
| `createTreeWalker` | `DOM.create_tree_walker/1,2,3` |
| `createNodeIterator` | `DOM.create_node_iterator/1,2,3` |
| `customElements.define` / `get` | `DOM.define_element/3` / `DOM.custom_element_get/2` |
| `setTimeout` / `clearTimeout` | `DOM.set_timeout/3` / `DOM.clear_timeout/2` |
| `setInterval` / `clearInterval` | `DOM.set_interval/3` / `DOM.clear_interval/2` |
| `queueMicrotask` | `DOM.queue_microtask/2` |

### `Node` / `EventTarget` / `ChildNode` / `ParentNode` → `DOM.Node`

| WHATWG | Dominique |
|---|---|
| `nodeType` / `nodeName` / `nodeValue` | `DOM.Node.node_type/1` / `node_name/1` / `value/1` |
| `textContent` (get / set) | `DOM.Node.text_content/1` / `set_text_content/2` |
| `parentNode` / `childNodes` | `DOM.Node.parent_node/1` / `child_nodes/1` |
| `firstChild` / `lastChild` | `DOM.Node.first_child/1` / `last_child/1` |
| `nextSibling` / `previousSibling` | `DOM.Node.next_sibling/1` / `previous_sibling/1` |
| `children` / `childElementCount` | `DOM.Node.children/1` / `child_element_count/1` |
| `first/lastElementChild` | `DOM.Node.first_element_child/1` / `last_element_child/1` |
| `next/previousElementSibling` | `DOM.Node.next_element_sibling/1` / `previous_element_sibling/1` |
| `hasChildNodes` | `DOM.Node.has_child_nodes/1` |
| `ownerDocument` | `DOM.Node.owner_document/1` |
| `appendChild` / `insertBefore` | `DOM.Node.append_child/2` / `insert_before/3` |
| `removeChild` / `replaceChild` | `DOM.Node.remove_child/2` / `replace_child/3` |
| `append` / `prepend` | `DOM.Node.append/2` / `prepend/2` |
| `before` / `after` / `replaceWith` | `DOM.Node.before/2` / `after/2` / `replace_with/2` |
| `remove` | `DOM.Node.remove/1` |
| `cloneNode` | `DOM.Node.clone_node/1,2` |
| `normalize` | `DOM.Node.normalize/1` |
| `contains` | `DOM.Node.contains/2` |
| `isSameNode` / `isEqualNode` | `DOM.Node.is_same_node/2` / `is_equal_node/2` |
| `compareDocumentPosition` | `DOM.Node.compare_document_position/2` |
| `isConnected` | `DOM.Node.is_connected/1` |
| `getRootNode` | `DOM.Node.get_root_node/1,2` |
| `assignedSlot` | `DOM.Node.assigned_slot/1` |
| `focus` / `blur` | `DOM.Node.focus/1` / `blur/1` |
| `addEventListener` / `removeEventListener` | `DOM.Node.add_event_listener/4` / `remove_event_listener/2,4` |
| `dispatchEvent` | `DOM.Node.dispatch_event/2` |
| `event.composedPath()` (at a node) | `DOM.Node.composed_path/2` |
| `DocumentType` `publicId` / `systemId` | `DOM.Node.doctype_ids/1` |

### `Attr` → `DOM.Node` (a `%DOM.Node{type: :attr}` handle)

| WHATWG | Dominique |
|---|---|
| `name` / `localName` | `DOM.Node.attr_name/1` / `attr_local_name/1` |
| `prefix` / `namespaceURI` | `DOM.Node.attr_prefix/1` / `attr_namespace_uri/1` |
| `value` (get / set) | `DOM.Node.attr_value/1` / `set_attr_value/2` |
| `ownerElement` | `DOM.Node.owner_element/1` |

### `Element` → `DOM.Element`

| WHATWG | Dominique |
|---|---|
| `localName` / `namespaceURI` | `DOM.Element.local_name/1` / `namespace/1` |
| `getAttribute` / `setAttribute` | `DOM.Element.get_attribute/2` / `set_attribute/3` |
| `hasAttribute` / `removeAttribute` | `DOM.Element.has_attribute/2` / `remove_attribute/2` |
| `toggleAttribute` | `DOM.Element.toggle_attribute/2,3` |
| `getAttributeNames` | `DOM.Element.get_attribute_names/1` |
| `getAttributeNS` / `setAttributeNS` | `DOM.Element.get_attribute_ns/3` / `set_attribute_ns/4` |
| `getAttributeNode` / `NS` | `DOM.Element.get_attribute_node/2` / `get_attribute_node_ns/3` |
| `setAttributeNode` / `removeAttributeNode` | `DOM.Element.set_attribute_node/2` / `remove_attribute_node/2` |
| `querySelector` / `All` | `DOM.Element.query_selector/2` / `query_selector_all/2` |
| `matches` / `closest` | `DOM.Element.matches/2` / `closest/2` |
| `innerHTML` (get / set) | `DOM.Element.inner_html/1` / `set_inner_html/2` |
| `outerHTML` (get / set) | `DOM.Element.outer_html/1` / `set_outer_html/2` |
| `insertAdjacentHTML` / `Element` / `Text` | `DOM.Element.insert_adjacent_html/3` / `_element/3` / `_text/3` |
| `attachShadow` / `shadowRoot` | `DOM.Element.attach_shadow/2,3` / `shadow_root/1` |
| `lookupPrefix` / `lookupNamespaceURI` | `DOM.Element.lookup_prefix/2` / `lookup_namespace_uri/2` |

### Other interfaces

| WHATWG interface | Dominique module | notable members |
|---|---|---|
| `DocumentFragment` (`ParentNode`) | `DOM.DocumentFragment` | `query_selector/2`, `query_selector_all/2` |
| `ShadowRoot` | `DOM.ShadowRoot` | `host/1`, `mode/1`, `inner_html/1`, `query_selector/2` |
| `HTMLSlotElement` | `DOM.Slot` | `assigned_nodes/1`, `assigned_elements/1`, `assign/2` |
| `Range` | `DOM.Range` | `set_start/3`, `set_end/3`, `extract_contents/1`, `surround_contents/2`, `compare_boundary_points/3` |
| `TreeWalker` | `DOM.TreeWalker` | `current_node/1`, `next_node/1`, `parent_node/1`, … |
| `NodeIterator` | `DOM.NodeIterator` | `next_node/1`, `previous_node/1`, `reference_node/1` |
| `Event` | `DOM.Event` | `new/1,2`, `prevent_default/1`, `stop_propagation/1`, `stop_immediate_propagation/1` |
| `AbortController` | `DOM.AbortController` | `new/1`, `signal/1`, `abort/1,2` |
| `AbortSignal` | `DOM.AbortSignal` | `aborted?/1`, `reason/1`, `throw_if_aborted/1`, `timeout/2`, `any/2` |
| `MutationObserver` | `DOM.MutationObserver` | `new/2`, `observe/3`, `disconnect/1`, `take_records/1` |

Interaction state that a browser drives from real input (`:hover`/`:active`/`:target`,
fragment navigation) is set through convenience functions on `DOM`
(`set_hover/1`, `set_active/1`, `set_fragment/2`, `set_indeterminate/2`, …), since
Dominique has no pointer/URL layer.

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
