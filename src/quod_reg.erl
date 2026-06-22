-module(quod_reg).
-moduledoc """
gproc registration nomenclature for quod.

Every quod process registers a unique **name** and posts its events to a
matching **property**, both keyed by the same `Key = {Type, Id}`:

| gproc entry | form          | use                                                |
| ----------- | ------------- | -------------------------------------------------- |
| name        | `{n, l, Key}` | unique, addressable via `{via, gproc, {n,l,Key}}`  |
| property    | `{p, l, Key}` | subscribable; the process posts its events here    |

## Key conventions

| `Key`                 | identifies                                  |
| --------------------- | ------------------------------------------- |
| `{transport, node}`   | the QUIC transport gen_server (singleton)   |
| `{sup, node}`         | the root supervisor                         |
| `{peer, PeerId}`      | a connected peer's handler (one per peer)   |
| `{channel, Name}`     | a pub/sub channel (property only, no owner) |

## Example

```erlang
%% an interested process subscribes to peer P's events...
quod_reg:subscribe({peer, P}),
%% ...and P's handler posts one:
quod_reg:publish({peer, P}, {quod_peer_down, Peer, closed}).
```
""".

-export([name/1, prop/1, via/1, where/1]).
-export([reg/1, publish/2, subscribe/1, unsubscribe/1]).

-export_type([key/0]).
-type key() :: {Type :: atom(), Id :: term()}.

%% --- key constructors ----------------------------------------------------

-doc "The gproc **name** entry for `Key`.".
-spec name(key()) -> {n, l, key()}.
name(Key) -> {n, l, Key}.

-doc "The gproc **property** entry for `Key`.".
-spec prop(key()) -> {p, l, key()}.
prop(Key) -> {p, l, Key}.

-doc "A `{via, gproc, _}` ref for `Key` — pass to `gen_server`/`supervisor`.".
-spec via(key()) -> {via, gproc, {n, l, key()}}.
via(Key) -> {via, gproc, {n, l, Key}}.

-doc "Pid currently owning `Key`'s name, or `undefined`.".
-spec where(key()) -> pid() | undefined.
where(Key) -> gproc:where({n, l, Key}).

%% --- registration / pub-sub ---------------------------------------------

-doc """
Register the **current** process under `Key`'s name. Use from spawned loops
that aren't started via `{via, gproc, _}`.
""".
-spec reg(key()) -> true.
reg(Key) -> gproc:reg({n, l, Key}).

-doc "Post `Event` to every process subscribed to `Key`'s property.".
-spec publish(key(), term()) -> term().
publish(Key, Event) -> gproc:send({p, l, Key}, Event).

-doc "The **current** process starts receiving `Key`'s events.".
-spec subscribe(key()) -> true.
subscribe(Key) -> gproc:reg({p, l, Key}).

-doc "The **current** process stops receiving `Key`'s events.".
-spec unsubscribe(key()) -> true.
unsubscribe(Key) -> gproc:unreg({p, l, Key}).
