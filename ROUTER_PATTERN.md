# GenServer Router Pattern

Use the router pattern for every GenServer and GenServer-like module. The
pattern keeps OTP callbacks mechanical, places behavior behind named
implementation functions, and makes the module's public protocol easy to
inspect.

## Module organization

Organize a GenServer in this order:

1. Lifecycle and initialization (`child_spec/1`, `start_link/1`, `init/1`)
2. API declarations
3. API and message-handler implementations
4. Private helpers
5. OTP callback router

Use section dividers in modules large enough to benefit from them:

```elixir
# ============================================================================
# API
# ============================================================================
```

Use spec dislocation: keep public types and specs together in one cohesive API
section. Include specs for private handlers of `info`, `continue`, and other
internal protocols there as well. This provides a single place to inspect the
server's complete contract without crossing implementation details.

Do not duplicate a public API spec with a spec for its corresponding
`*_impl` function. Add an implementation spec only for a private handler that
has no public or cross-module API entry point, such as an `info` or `continue`
handler.

Function bodies do not live in the API declaration section. In the
implementations section, place each public API function immediately before its
corresponding private `_impl` function.

## API declarations

Group the API surface without implementation bodies:

```elixir
@type node_id :: reference()

@spec insert(GenServer.server(), node_id(), node_id()) :: :ok
@spec status(GenServer.server()) :: :ready | :busy

@spec timeout_impl(reference(), state()) :: {:noreply, state()}
```

Expose named public functions rather than requiring callers to know GenServer
message formats. Message formats are private implementation details. Public
functions describe intent and provide the stable interface.

Default to `GenServer.call/3`, including commands whose successful result is
only `:ok`. Calls preserve backpressure and make overload visible to callers.
Use `GenServer.cast/2` only when removing backpressure is intentional and the
resulting mailbox growth, ordering, and failure behavior have been explicitly
modeled.

Use `handle_info/2` only for messages whose protocol is defined outside the
GenServer's public API, such as timers, monitors, task replies, ports, PubSub
deliveries, and direct messages from another subsystem.

## Implementations

Group each public API function body with the private implementation that
handles its message:

```elixir
def status(server), do: GenServer.call(server, :status)

defp status_impl(state), do: {:reply, state.status, state}

def insert(server, parent_id, node_id) do
  GenServer.call(server, {:insert, parent_id, node_id})
end

defp insert_impl(parent_id, node_id, state) do
  {:reply, :ok, insert_node(parent_id, node_id, state)}
end
```

Name message implementations with an `_impl` suffix. Implementation
functions:

- contain the business logic and state transitions
- receive extracted message values rather than the original message envelope
- receive `from` only when they actually use it
- return the complete OTP callback tuple
- may have multiple clauses when domain-level pattern matching is useful

Important state transitions should have explicit names rather than being
buried in branching inside an OTP callback.

## Router

Place the router at the bottom of the module. Router clauses only pattern
match, extract parameters, and delegate:

```elixir
@impl true
def handle_call(:status, _from, state), do: status_impl(state)

@impl true
def handle_call({:insert, parent_id, node_id}, _from, state) do
  insert_impl(parent_id, node_id, state)
end

@impl true
def handle_info({:timeout, ref}, state), do: timeout_impl(ref, state)

@impl true
def handle_continue(:microtask_checkpoint, state) do
  checkpoint_impl(state)
end
```

The router must not perform business logic, I/O, persistence, branching, or
state transitions. Pattern matching that distinguishes message shapes belongs
in router clauses; decisions based on domain state belong in implementation
functions.

Do not add defensive catch-all clauses merely to hide an unexpected message.
An unsupported message should fail unless ignoring it is an intentional part
of the server's protocol.

Trivial callbacks that only preserve OTP semantics may remain inline when an
implementation function would reduce clarity:

```elixir
@impl true
def handle_info(:noop, state), do: {:noreply, state}
```

## Complete example

```elixir
defmodule Example.Store do
  use GenServer

  # ==========================================================================
  # TYPES
  # ==========================================================================

  defstruct values: %{}

  # typically state should be a struct of this module, but if the state truly
  # is simple, it can be a single term.  Use judgement.
  @type state :: %__MODULE__{}
  @type t :: GenServer.server()

  # ==========================================================================
  # Lifecycle
  # ==========================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}, {:continue, :bootstrap}}
  end

  # ==========================================================================
  # API
  # ==========================================================================

  @spec fetch(t(), term()) :: {:ok, term()} | :error
  @spec put(t(), term(), term()) :: :ok

  # private api, for handlers for info, continue, etc which do not have
  # a public surface area.

  @spec bootstrap_impl(state()) :: {:noreply, state()}

  # ==========================================================================
  # Implementations
  # ==========================================================================

  def fetch(server, key), do: GenServer.call(server, {:fetch, key})

  defp fetch_impl(key, state) do
    {:reply, Map.fetch(state.values, key), state}
  end

  def put(server, key, value), do: GenServer.call(server, {:put, key, value})

  defp put_impl(key, value, state) do
    next_state = put_in(state.values[key], value)
    {:reply, :ok, next_state}
  end

  defp bootstrap_impl(state) do
    {:noreply, state}
  end

  # ==========================================================================
  # HELPER FUNCTIONS
  # ==========================================================================

  # section for any functions which appear in more than one impl function.
  # otherwise encapsulation functions should appear beneath their impl function.

  # ==========================================================================
  # Router
  # ==========================================================================

  @impl true
  def handle_continue(:bootstrap, state), do: bootstrap_impl(state)

  @impl true
  def handle_call({:fetch, key}, _from, state), do: fetch_impl(key, state)

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    put_impl(key, value, state)
  end
end
```

The API provides a compact inventory of the public contract. The router
provides a compact inventory of accepted messages, while the implementation
section contains the behavior behind them.
