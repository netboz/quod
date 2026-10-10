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
| `{ask_router, node}`  | bounded remote proof-scope router            |
| `{sup, node}`         | the root supervisor                         |
| `{directory, node}`   | the local route-directory owner             |
| `{directory_control, node}` | directory dissemination/control    |
| `{foreign_log, node}` | anchored foreign-log verifier/cache         |
| `{foreign_cache_writer, {Namespace, Anchor}}` | existing verifier's exclusive cache mutation lifetime |
| `{namespace_manager, node}` | desired per-ontology process sets   |
| `{quod_ns_sup, node}` | dynamic content-subtree supervisor          |
| `{quod_brahms_sup, node}` | dynamic Brahms supervisor             |
| `{quod_ns, Ns}`       | an ontology's content sub-supervisor        |
| `{quod_brahms, Ns}`   | a namespace's Brahms statem (one per Ns)    |
| `{quod_simplex, Ns}`  | a namespace's consensus statem              |
| `{quod_prolog, Ns}`   | a namespace's committed fact engine         |
| `{quod_runtime, Ns}`  | a namespace's derived runtime projection    |
| `{connections, local}` | local connection owners (property)         |
| `{channel, Name}`     | a pub/sub channel (property only, no owner) |
| `{directory_route, {Namespace, Anchor}}` | exact route availability (property only) |

## Example

```erlang
%% an interested process subscribes to a channel's messages...
quod_reg:subscribe({channel, Ns}),
%% ...and a link on that channel posts one:
quod_reg:publish({channel, Ns}, {quod_message, {Peer, self()}, Ns, Payload}).
```
""".

-export([name/1, prop/1, via/1, where/1]).
-export([reg/1, publish/2, subscribe/1, unsubscribe/1,
         publish_tracked/2, subscribe_tracked/1, unsubscribe_tracked/1,
         tracked_subscribers/1, track_subscribers/1, untrack_subscribers/1,
         monitor_name/2, demonitor_name/2]).

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

-doc "Post an event on a resource channel whose subscriber lifetime can be tracked.".
-spec publish_tracked(key(), term()) -> term().
publish_tracked(Key, Event) -> gproc:send({r, l, Key}, Event).

-doc "Subscribe before acquiring the owner's resource; process death also releases the interest.".
-spec subscribe_tracked(key()) -> true.
subscribe_tracked(Key) -> gproc:reg({r, l, Key}).

-doc "Release the current process's tracked channel interest.".
-spec unsubscribe_tracked(key()) -> true.
unsubscribe_tracked(Key) -> gproc:unreg({r, l, Key}).

-doc "Live processes interested in a tracked channel.".
-spec tracked_subscribers(key()) -> [pid()].
tracked_subscribers(Key) ->
    [Pid || Pid <- gproc:lookup_pids({r, l, Key}), is_process_alive(Pid)].

-doc """
The current resource owner receives `{gproc, resource_on_zero, l, Key, Owner}`
when the last tracked interest disappears. Existing interests are included.
There is one counter owner per channel; its death removes the counter.
""".
-spec track_subscribers(key()) -> true.
track_subscribers(Key) ->
    gproc:reg({rc, l, Key}, undefined, [{on_zero, [{send, self()}]}]).

-doc "Stop owning the channel's subscriber counter when forgetting its resource.".
-spec untrack_subscribers(key()) -> true.
untrack_subscribers(Key) -> gproc:unreg({rc, l, Key}).

-doc "Monitor a unique local name, optionally following owner replacement.".
-spec monitor_name(key(), info | follow | standby) -> reference().
monitor_name(Key, Type) -> gproc:monitor(name(Key), Type).

-doc "Remove a unique-name monitor created by monitor_name/2.".
-spec demonitor_name(key(), reference()) -> ok.
demonitor_name(Key, Ref) -> gproc:demonitor(name(Key), Ref).
