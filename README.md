# Dominique

**TODO: Add description**

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
