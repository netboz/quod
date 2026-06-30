-module(quod_quic).
-moduledoc """
QUIC transport over the pure-Erlang `quic` library: the **server** + dialer and
the **connection authority**.

It starts the `quic` server (each accepted connection is handed to a
`m:quod_conn` owner via `connection_handler`), and serializes outbound
connection creation so there is **one connection per peer** (no dial race).
Streams/links and message delivery live in `m:quod_conn` / `m:quod_link`.

Upper layers use one async call:

```erlang
quod_quic:open_link(NodeId, Channel)        %% -> caller gets {link_up, NodeId, Channel, LinkPid}
quod_link:send(LinkPid, Payload)              %% direct, non-blocking
%% messages arrive on the gproc property {channel, Channel}
%% erlang:monitor(LinkPid) -> 'DOWN' is the disconnect
```

> #### Why pure Erlang {: .info }
>
> `quic` is a process-per-connection pure-Erlang stack — no `quicer`/msquic NIF,
> so no C toolchain or from-source build, and a small, predictable image. (The
> per-node footprint is governed by the BEAM, not the QUIC backend: cap the port
> table with `+Q` in vm.args or a container's huge default `nofile` preallocates
> ~1.5 GB of `port_table`.)
""".

-behaviour(gen_server).

-export([start_link/0, open_link/2, learn/2, resolve/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(KEY, {transport, node}).
-define(SERVER, quod_quic).
-define(ADDR_CACHE, quod_addr_cache).   %% public ETS: pubkey() => endpoint() (resolution hints)

%% `self` is the transport identity `{Pubkey, Addr}` announced in every link header:
%% Pubkey = the node's `node_id` (its Ed25519 key, or its address in the no-identity/test
%% path), Addr = where it listens. The receiver binds the proven peer pubkey to it and learns
%% Pubkey => Addr for resolution.
-record(state, {self, alpn, cert, key, conns = #{}}).

%% ======================================================================
%% API
%% ======================================================================

start_link() ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, [], []).

-doc """
Open (or reuse) a link to `Target` for `Channel`. `Target` is either a **`node_id()`**
(a pubkey — resolved to an address via the hint cache; `link_error` if not yet known)
or a **`{Host,Port}`** endpoint (dialed directly — for seeds/contacts whose pubkey is
not yet known). Asynchronous: the caller receives `{link_up, Target, Channel, LinkPid}`
(or `{link_error, Target, Channel}`).
""".
-spec open_link(binary() | {inet:hostname(), inet:port_number()}, binary()) -> ok.
open_link(Target, Channel) ->
    gen_server:cast(quod_reg:via(?KEY), {open_link, Target, Channel, self()}).

-doc "Record a `Pubkey => Endpoint` resolution hint (learned from a header / gossip).".
-spec learn(binary(), {inet:hostname(), inet:port_number()}) -> ok.
learn(Pubkey, Endpoint) when is_binary(Pubkey) ->
    _ = ensure_cache(),
    true = ets:insert(?ADDR_CACHE, {Pubkey, Endpoint}),
    ok;
learn(_, _) -> ok.   %% non-pubkey id (the test/no-identity path): nothing to resolve

-doc "Resolve a target to a dialable endpoint: an endpoint dials direct; a pubkey via the cache.".
-spec resolve(term()) -> {ok, {inet:hostname(), inet:port_number()}} | error.
resolve({Host, Port} = Endpoint) when is_integer(Port), Port > 0, Port =< 65535,
                                      (is_list(Host) orelse is_binary(Host) orelse
                                       is_atom(Host) orelse is_tuple(Host)) ->
    {ok, Endpoint};
resolve(Pubkey) when is_binary(Pubkey) ->
    try ets:lookup(?ADDR_CACHE, Pubkey) of
        [{_, Endpoint}] -> {ok, Endpoint};
        []              -> error
    catch error:badarg -> error   %% cache not created yet (transport not started)
    end;
resolve(_) -> error.

%% ======================================================================
%% gen_server
%% ======================================================================

init([]) ->
    process_flag(trap_exit, true),
    Port = env(listen_port, 14567),
    ALPN = [to_bin(env(alpn, "quod"))],
    Addr = env(node_addr, env(node_id, {"127.0.0.1", Port})),  %% where we listen (the hint)
    %% Our node_id: the Ed25519 pubkey (set by quod_app:apply_identity). With no identity
    %% (legacy/test boots) it is the address — so ids stay {Host,Port} and dial directly.
    Pubkey = env(node_pubkey, Addr),
    Self = {Pubkey, Addr},
    {Cert, Key} = identity_certkey(),
    _ = ensure_cache(),
    seed_hints(env(addr_hints, #{})),     %% bootstrap pubkey=>endpoint hints (multi-voter create / CT)
    Handler = fun(Conn) -> {ok, quod_conn:start_inbound(Conn, Self)} end,
    %% `verify => true` makes the server REQUEST + verify the client's cert: the TLS 1.3
    %% CertificateVerify proves the peer holds its keypair, WITHOUT a CA chain — so per-node
    %% self-signed Ed25519 certs authenticate the peer pubkey (read via `quic:peercert/1`,
    %% bound to the header's claimed pubkey in `m:quod_conn`). We present our own cert when
    %% dialing too (`quod_conn:start_outbound`), so every directed pair is mutually authenticated.
    ServerOpts = #{cert => Cert, key => Key, verify => true, alpn => ALPN,
                   connection_handler => Handler},
    case quic:start_server(?SERVER, Port, ServerOpts) of
        {ok, _} ->
            logger:info("quod: QUIC (pure Erlang) listening on ~p (alpn ~s, id ~s @ ~p)",
                        [Port, hd(ALPN), id_str(Pubkey), Addr]),
            {ok, #state{self = Self, alpn = ALPN, cert = Cert, key = Key}};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% the connection authority: one connection per peer, created here. Resolve the target
%% to an endpoint first (a pubkey via the cache, an endpoint directly); a miss ⇒
%% `link_error` so the caller retries once the address is learned (header / gossip).
handle_cast({open_link, Target, Channel, ReplyTo}, State) ->
    case resolve(Target) of
        {ok, Endpoint} ->
            {ConnPid, State1} = ensure_conn(Target, Endpoint, State),
            quod_conn:open_link(ConnPid, Channel, ReplyTo),
            {noreply, State1};
        error ->
            logger:debug("quod: open_link target ~p unresolved/non-dialable", [Target]),
            ReplyTo ! {link_error, Target, Channel},
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #state{conns = Conns}) ->
    {noreply, State#state{conns = maps:filter(fun(_, P) -> P =/= Pid end, Conns)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = quic:stop_server(?SERVER),
    ok.

%% ======================================================================
%% connection authority
%% ======================================================================

%% Reuse OUR OWN outbound connection to this peer, or dial a fresh one. We deliberately
%% do NOT adopt a connection the peer dialed to us: a stream we open on an adopted
%% (peer-initiated) connection is *server-initiated* (QUIC stream ids 1,5,9…), the
%% lesser-tested path with its own flow-control limits. Always being the client for our
%% own outgoing streams keeps us on the proven client-initiated path. The cost is one
%% connection per direction (two per pair) instead of a shared one — cheap and reliable.
%% Keyed by `Target` (the pubkey for a member, or the endpoint for a bootstrap seed) so the
%% caller and reuse stay consistent with how it asked; the dial goes to the resolved `Endpoint`.
ensure_conn(Target, Endpoint, State = #state{conns = Conns}) ->
    case maps:get(Target, Conns, undefined) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true  -> {Pid, State};
                false -> start_conn(Target, Endpoint, State)
            end;
        undefined ->
            start_conn(Target, Endpoint, State)
    end.

start_conn(Target, {Host, Port}, State = #state{conns = Conns, self = Self, alpn = ALPN,
                                                cert = Cert, key = Key}) ->
    Pid = quod_conn:start_outbound(Host, Port, Target, Self, ALPN, Cert, Key),
    _ = erlang:monitor(process, Pid),
    {Pid, State#state{conns = maps:put(Target, Pid, Conns)}}.

%% ======================================================================
%% helpers
%% ======================================================================

%% The pubkey=>endpoint resolution cache. A named, public set so links (any process) can
%% `learn/2` and the ledger can `resolve/1` without round-tripping this gen_server. Created
%% once at boot; `ensure_cache/0` is idempotent.
ensure_cache() ->
    case ets:info(?ADDR_CACHE, name) of
        undefined -> ets:new(?ADDR_CACHE, [named_table, public, set, {read_concurrency, true}]);
        _         -> ?ADDR_CACHE
    end.

seed_hints(Hints) when is_map(Hints) ->
    _ = maps:foreach(fun(PK, EP) -> learn(PK, EP) end, Hints), ok;
seed_hints(_) -> ok.

%% short, log-readable id: a real pubkey via quod_identity, an address shown as-is.
id_str(Pubkey) when is_binary(Pubkey) -> quod_identity:short(Pubkey);
id_str(Other)                         -> io_lib:format("~p", [Other]).

%% The node's transport cert+key. Production: the per-node Ed25519 identity, set in the
%% app env by `quod_app:apply_identity` (DER cert + `#'ECPrivateKey'{}` key). Legacy/test
%% boots with no identity fall back to a PEM file pair (`certfile`/`keyfile`).
identity_certkey() ->
    %% get_env yields the bare atom `undefined` when unset, so an absent key misses the
    %% `{ok, _}` pattern and falls to the PEM fallback (no guard needed).
    case {application:get_env(quod, identity_cert), application:get_env(quod, identity_key)} of
        {{ok, Cert}, {ok, Key}} ->
            {Cert, Key};
        _ ->
            {load_cert(env(certfile, "priv/certs/cert.pem")),
             load_key(env(keyfile, "priv/certs/key.pem"))}
    end.

%% certs: load the PEM file -> DER cert / decoded key term (what `quic` expects).
load_cert(File) ->
    {ok, Pem} = file:read_file(File),
    [Der | _] = [D || {'Certificate', D, _} <- public_key:pem_decode(Pem)],
    Der.

load_key(File) ->
    {ok, Pem} = file:read_file(File),
    [{Type, Der, _} | _] = [E || {T, _, _} = E <- public_key:pem_decode(Pem), T =/= 'Certificate'],
    public_key:der_decode(Type, Der).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L);
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8).

env(Key, Default) -> application:get_env(quod, Key, Default).
