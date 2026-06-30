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

-export([start_link/0, open_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(KEY, {transport, node}).
-define(SERVER, quod_quic).

-record(state, {self, alpn, cert, key, conns = #{}}).

%% ======================================================================
%% API
%% ======================================================================

start_link() ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, [], []).

-doc """
Open (or reuse) a link to `NodeId = {Host,Port}` for `Channel`. Asynchronous: the
caller receives `{link_up, NodeId, Channel, LinkPid}` when it is ready (or
`{link_error, NodeId, Channel}`).
""".
-spec open_link({inet:hostname(), inet:port_number()}, binary()) -> ok.
open_link(NodeId, Channel) ->
    gen_server:cast(quod_reg:via(?KEY), {open_link, NodeId, Channel, self()}).

%% ======================================================================
%% gen_server
%% ======================================================================

init([]) ->
    process_flag(trap_exit, true),
    Port = env(listen_port, 14567),
    ALPN = [to_bin(env(alpn, "quod"))],
    Self = env(node_id, {"127.0.0.1", Port}),
    {Cert, Key} = identity_certkey(),
    Handler = fun(Conn) -> {ok, quod_conn:start_inbound(Conn, Self)} end,
    %% `verify => true` makes the server REQUEST + verify the client's cert: the TLS 1.3
    %% CertificateVerify proves the peer holds its keypair, WITHOUT a CA chain — so per-node
    %% self-signed Ed25519 certs authenticate the peer pubkey (read via `quic:peercert/1`,
    %% used as the node identity from A.3). We present our own cert when dialing too
    %% (`quod_conn:start_outbound`), so every directed pair is mutually authenticated.
    ServerOpts = #{cert => Cert, key => Key, verify => true, alpn => ALPN,
                   connection_handler => Handler},
    case quic:start_server(?SERVER, Port, ServerOpts) of
        {ok, _} ->
            logger:info("quod: QUIC (pure Erlang) listening on ~p (alpn ~s, node_id ~p)",
                        [Port, hd(ALPN), Self]),
            {ok, #state{self = Self, alpn = ALPN, cert = Cert, key = Key}};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% the connection authority: one connection per peer, created here.
handle_cast({open_link, NodeId, Channel, ReplyTo}, State) ->
    case dialable(NodeId) of
        true ->
            {ConnPid, State1} = ensure_conn(NodeId, State),
            quod_conn:open_link(ConnPid, Channel, ReplyTo),
            {noreply, State1};
        false ->
            logger:warning("quod: open_link to non-dialable node id ~p dropped", [NodeId]),
            ReplyTo ! {link_error, NodeId, Channel},
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
ensure_conn(NodeId, State = #state{conns = Conns}) ->
    case maps:get(NodeId, Conns, undefined) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true  -> {Pid, State};
                false -> start_conn(NodeId, State)
            end;
        undefined ->
            start_conn(NodeId, State)
    end.

start_conn({Host, Port} = NodeId, State = #state{conns = Conns, self = Self, alpn = ALPN,
                                                 cert = Cert, key = Key}) ->
    Pid = quod_conn:start_outbound(Host, Port, NodeId, Self, ALPN, Cert, Key),
    _ = erlang:monitor(process, Pid),
    {Pid, State#state{conns = maps:put(NodeId, Pid, Conns)}}.

%% ======================================================================
%% helpers
%% ======================================================================

%% a node id is dialable only if it is a `{Host, Port}` with a valid port.
dialable({Host, Port}) when is_integer(Port), Port > 0, Port =< 65535 ->
    is_list(Host) orelse is_binary(Host) orelse is_atom(Host) orelse is_tuple(Host);
dialable(_) ->
    false.

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
