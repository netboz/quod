-module(quod_quic).
-moduledoc """
QUIC transport over the pure-Erlang `quic` library: the **server** + dialer and
the **connection authority**.

It starts the `quic` server (each accepted connection is handed to a
`m:quod_conn` owner via `connection_handler`), and serializes outbound
connection creation per pool key (ordinary, pinned, or identity-discovery; no dial
race within a pool). Streams/links and message delivery live in
`m:quod_conn` / `m:quod_link`.

Ordinary channels pick one of two send models:

```erlang
%% (a) fire-and-forget — the transport owns the link; buffers until it is ready:
quod_quic:send(NodeId, Channel, Frame)        %% non-blocking; no link to track
%% (b) manage the link yourself (needed for liveness/failover — Brahms, consensus):
quod_quic:open_link(NodeId, Channel)          %% -> caller gets {link_up, NodeId, Channel, LinkPid}
quod_link:send(LinkPid, Payload)              %% then send on the LinkPid directly
%% erlang:monitor(LinkPid) -> 'DOWN' is the disconnect
%% either way, ordinary inbound messages arrive on the gproc property {channel, Channel}
```

Catch-up channels instead bind one producer to the opened link and exchange
pages through `quod_link:request_page/6` and exact-owner credit/result callbacks.
Their inbound requests go directly to the registered catch-up endpoint, never
through channel-wide gproc publication.

> #### Why pure Erlang {: .info }
>
> `quic` is a process-per-connection pure-Erlang stack — no `quicer`/msquic NIF,
> so no C toolchain or from-source build, and a small, predictable image. (The
> per-node footprint is governed by the BEAM, not the QUIC backend: cap the port
> table with `+Q` in vm.args or a container's huge default `nofile` preallocates
> ~1.5 GB of `port_table`.)
""".

-behaviour(gen_server).

-export([start_link/0, open_link/2, open_link_tagged/2, open_link_pinned/3,
         open_link_pinned_lease/3,
         release_link_pinned/4,
         open_link_identified/2,
         send/3, send_pinned/4,
         learn/2, learn_if_absent/2, resolve/1, valid_endpoint/1,
         liveness_opts/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([ensure_cache/0]).   %% tests own the resolver cache themselves (store_hint no longer creates it)
-export([identity_certkey/0]).   %% tests exercise the PEM-fallback error path directly
-endif.

-define(KEY, {transport, node}).
-define(SERVER, quod_quic).
-define(ADDR_CACHE, quod_addr_cache).   %% public ETS: pubkey() => endpoint() (resolution hints)

%% `self` is the transport identity `{Pubkey, Addr}` announced in every link header, where the
%% two slots are DISTINCT: Pubkey = the node's Ed25519 identity (`node_pubkey`),
%% Addr = the advertised `{Host,Port}` peers dial
%% (`node_addr`, which may differ from the local bind port). The receiver binds the proven peer
%% pubkey and learns Pubkey => Addr — but only when Addr is a real endpoint (see `learn/2`).
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

-doc "Correlated ordinary-pool open; replies carry the returned reference.".
-spec open_link_tagged(binary() | {inet:hostname(), inet:port_number()}, binary()) ->
          reference().
open_link_tagged(Target, Channel) ->
    Ref = make_ref(),
    gen_server:cast(quod_reg:via(?KEY),
                    {open_link, Target, Channel, {self(), Ref}}),
    Ref.

-doc """
Open a directory-scoped link by dialing `Endpoint` while pinning the TLS peer to
`NodeKey`. The connection is isolated from the ordinary target pool and its link
header requests no address-hint learning. On success the caller receives
`{link_up, Ref, NodeKey, Channel, LinkPid}`; the shared address cache is
untouched. `Ref` is the reference returned by this call.
""".
-spec open_link_pinned(binary(), {inet:hostname(), inet:port_number()}, binary()) ->
          reference().
open_link_pinned(NodeKey, Endpoint, Channel) ->
    Ref = make_ref(),
    gen_server:cast(
      quod_reg:via(?KEY),
      {open_link_pinned, NodeKey, Endpoint, Channel, {self(), Ref}}),
    Ref.

-doc """
Acquire a request-scoped pinned-link lease. It opens/reuses the same pinned
connection and stream as `open_link_pinned/3`, but the returned reference must
later be passed to `release_link_pinned/4`. This is for bounded operations whose
owner process outlives an individual request.
""".
-spec open_link_pinned_lease(
        binary(), {inet:hostname(), inet:port_number()}, binary()) -> reference().
open_link_pinned_lease(NodeKey, Endpoint, Channel) ->
    Ref = make_ref(),
    gen_server:cast(
      quod_reg:via(?KEY),
      {open_link_pinned_lease, NodeKey, Endpoint, Channel, {self(), Ref}}),
    Ref.

-doc """
Release the exact `{caller, Ref}` lease created by
`open_link_pinned_lease/3`.
This only consults the existing pinned connection; cleanup never dials or
creates transport state. The channel stays open while another exact lease (or
a connection-owned send) still uses it.
""".
-spec release_link_pinned(binary(), {inet:hostname(), inet:port_number()},
                          binary(), reference()) -> ok.
release_link_pinned(NodeKey, Endpoint, Channel, Ref)
  when is_binary(NodeKey), is_binary(Channel), is_reference(Ref) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            gen_server:cast(
              Pid,
              {release_link_pinned, NodeKey, Endpoint, Channel,
               {self(), Ref}});
        _ ->
            %% A stopped transport owns no surviving connections or leases.
            ok
    end.

-doc """
Open an identity-discovery link to `Endpoint`. The peer's TLS key is returned
in `{link_up, Ref, NodeKey, Channel, LinkPid}` after certificate/header
authentication. The isolated connection suppresses automatic address-hint
learning; its caller decides whether the identity is authorised and retained.
""".
-spec open_link_identified(
        {inet:hostname(), inet:port_number()}, binary()) ->
          reference().
open_link_identified(Endpoint, Channel) ->
    Ref = make_ref(),
    gen_server:cast(
      quod_reg:via(?KEY),
      {open_link_identified, Endpoint, Channel, {self(), Ref}}),
    Ref.

-doc """
Fire-and-forget send on an already-authenticated directory route. It dials the
explicit endpoint, pins the TLS peer to `NodeKey`, uses the isolated pinned
connection pool and suppresses shared-cache learning.
""".
-spec send_pinned(binary(), {inet:hostname(), inet:port_number()},
                  binary(), binary()) -> ok.
send_pinned(NodeKey, Endpoint, Channel, Frame) ->
    gen_server:cast(
      quod_reg:via(?KEY),
      {send_pinned, NodeKey, Endpoint, Channel, Frame}).

-doc """
**Fire-and-forget send** of `Frame` to `Target` on `Channel`. Opens (or reuses) the connection + link
like `open_link/2`, but the caller never sees the link: the connection reuses a live link or **buffers**
`Frame` until one is ready (`m:quod_conn`). Non-blocking; a resolve/connect failure silently drops the
frame (the caller relies on its own retry/anti-entropy). This is the send path for endpoints that don't
need the link lifecycle (`m:quod_feed`); use `open_link/2` when you
must monitor the link yourself (Brahms, consensus), or `open_link_tagged/2`
for a correlated catch-up binding.
""".
-spec send(binary() | {inet:hostname(), inet:port_number()}, binary(), binary()) -> ok.
send(Target, Channel, Frame) ->
    gen_server:cast(quod_reg:via(?KEY), {send, Target, Channel, Frame}).

-doc """
Record a `Pubkey => Endpoint` resolution hint, **overwriting** any existing one — for LIVE evidence
(an inbound link header, or a `peer_admitted` fact at the live commit that just passed a quorum of
readiness verdicts): the newest live sighting is the freshest address.
""".
-spec learn(binary(), {inet:hostname(), inet:port_number()}) -> ok.
learn(Pubkey, Endpoint) -> store_hint(Pubkey, Endpoint, insert).

-doc """
Record a `Pubkey => Endpoint` hint only if none exists yet — for HISTORICAL sources (a `peer_admitted`
fact replayed out of the committed log during catch-up): a replayed address may be stale (member ports
rot on redeploy), so it must fill a VOID, never clobber a live header hint. Live evidence (`learn/2`)
always wins.
""".
-spec learn_if_absent(binary(), {inet:hostname(), inet:port_number()}) -> ok.
learn_if_absent(Pubkey, Endpoint) -> store_hint(Pubkey, Endpoint, insert_new).

%% The one hint writer. NEVER creates the cache: the table is owned exclusively by the quod_quic
%% gen_server (created in init/1), so a hint written from a FOREIGN process (the quod_simplex statem's
%% learn hooks) can't end up owning a table that then dies with that process. A write before the table
%% exists (transport still starting / mid-restart) is a fail-closed no-op — `resolve/1` misses and the
%% caller retries once a header re-teaches the hint (mirrors resolve's own badarg posture).
store_hint(Pubkey, Endpoint, Op) when is_binary(Pubkey) ->
    case is_endpoint(Endpoint) of
        true  -> try case Op of
                         insert     -> ets:insert(?ADDR_CACHE, {Pubkey, Endpoint});
                         insert_new -> ets:insert_new(?ADDR_CACHE, {Pubkey, Endpoint})
                     end
                 catch error:badarg -> false   %% cache not created yet (transport not started)
                 end,
                 ok;
        false -> ok   %% a non-endpoint address must NEVER clobber a good hint
    end;
store_hint(_, _, _) -> ok.   %% non-pubkey ids are not resolvable transport identities

-doc "Resolve a target to a dialable endpoint: an endpoint dials direct; a pubkey via the cache.".
-spec resolve(term()) -> {ok, {inet:hostname(), inet:port_number()}} | error.
resolve(Endpoint) when is_tuple(Endpoint) ->        %% an endpoint dials direct
    case is_endpoint(Endpoint) of true -> {ok, Endpoint}; false -> error end;
resolve(Pubkey) when is_binary(Pubkey) ->           %% a pubkey resolves via the hint cache
    try ets:lookup(?ADDR_CACHE, Pubkey) of
        [{_, Endpoint}] ->
            %% never hand a non-endpoint downstream — a corrupt/stale hint is treated as a miss
            case is_endpoint(Endpoint) of true -> {ok, Endpoint}; false -> error end;
        [] -> error
    catch error:badarg -> error   %% cache not created yet (transport not started)
    end;
resolve(_) -> error.

%% A dialable network endpoint: `{Host, Port}` with a valid port and a host that is a hostname
%% string/binary or an `inet:ip_address()` tuple. The single predicate that keeps a pubkey (or any
%% non-endpoint) from ever being mistaken for an address (in `learn`/`resolve`). Atom hosts are
%% deliberately rejected so a header/config `{undefined, Port}` (or any atom) can't pass as an
%% address and poison the resolver — quod never uses atom hostnames.
is_endpoint({Host, Port}) when is_integer(Port), Port > 0, Port =< 65535 ->
    valid_host(Host);
is_endpoint(_) -> false.

valid_host(Host) when is_binary(Host) ->
    byte_size(Host) > 0 andalso byte_size(Host) =< 255;
valid_host(Host) when is_list(Host) ->
    length(Host) > 0 andalso length(Host) =< 255 andalso
        lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C =< 255 end,
                  Host);
valid_host(Host) when is_tuple(Host) ->
    inet:is_ip_address(Host);
valid_host(_) ->
    false.

-doc "True when `Endpoint` has the host/port shape accepted by the transport dialer.".
-spec valid_endpoint(term()) -> boolean().
valid_endpoint(Endpoint) -> is_endpoint(Endpoint).

%% ======================================================================
%% gen_server
%% ======================================================================

init([]) ->
    process_flag(trap_exit, true),
    Port    = env(listen_port, 14567),
    ALPN    = [to_bin(env(alpn, "quod"))],
    Pubkey0 = env(node_pubkey, undefined),
    case self_addr(env(node_addr, undefined), Pubkey0) of
        {error, Reason} ->
            logger:error("quod: transport init aborted: ~p", [Reason]),
            {stop, Reason};
        {ok, Addr} ->
            %% Identity and reachable address are two SEPARATE inputs. `node_pubkey` is the
            %% Ed25519 identity; `node_addr` is the advertised {Host,Port} others dial. A keyed
            %% node's address is deployment-specific (NAT / containers / port-mapping), so it is
            %% supplied explicitly — never the pubkey, never guessed from the bind port.
            Self   = {Pubkey0, Addr},
            case identity_certkey() of
                {error, CertReason} ->
                    logger:error("quod: transport init aborted: cert/key load failed: ~p",
                                 [CertReason]),
                    {stop, {cert_key_load_failed, CertReason}};
                {ok, {Cert, Key}} ->
                    start_listener(Port, ALPN, Self, Cert, Key)
            end
    end.

%% Bring up the listener once identity, address, and cert/key are all in hand.
start_listener(Port, ALPN, {Pubkey0, Addr} = Self, Cert, Key) ->
    _ = ensure_cache(),
    Authority = self(),
    Handler =
        fun(Conn) ->
            {ok, quod_conn:start_inbound(Conn, Self, Authority)}
        end,
    %% `verify => true` makes the server REQUEST + verify the client's cert: the TLS 1.3
    %% CertificateVerify proves the peer holds its keypair, WITHOUT a CA chain — so per-node
    %% self-signed Ed25519 certs authenticate the peer pubkey (read via `quic:peercert/1`,
    %% bound to the header's claimed pubkey in `m:quod_conn`). We present our own cert when
    %% dialing too (`quod_conn:start_outbound`), so every directed pair is mutually authenticated.
    %% QUIC liveness (idle_timeout + keep_alive_interval) for fast dead-peer detection,
    %% from config via `liveness_opts/0`. This quic build enforces each side's OWN
    %% idle_timeout (no RFC min negotiation), so `quod_conn` dials with the SAME opts
    %% (both call `liveness_opts/0`) for symmetric detection in both directions.
    ServerOpts = maps:merge(#{cert => Cert, key => quod_identity:tls_key(Key),
                              verify => true, alpn => ALPN,
                              connection_handler => Handler}, liveness_opts()),
    case quic:start_server(?SERVER, Port, ServerOpts) of
        {ok, _} ->
            logger:info("quod: QUIC (pure Erlang) listening on ~p (alpn ~s, id ~s @ ~p)",
                        [Port, hd(ALPN), id_str(Pubkey0), Addr]),
            {ok, #state{self = Self, alpn = ALPN, cert = Cert, key = Key}};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

%% A node's own advertised endpoint. `node_addr` (an explicit {Host,Port}) is the sole source:
%% a reachable address depends on the deployment and is NEVER derived from the local bind port.
%% A keyed node (real `node_pubkey`) with no `node_addr` is a misconfiguration — fail loudly at
%% boot rather than advertise a wrong/placeholder address. A transport without
%% an Ed25519 node identity cannot authenticate its link headers and is refused.
self_addr(NodeAddr, Pubkey) ->
    case {NodeAddr, Pubkey} of
        {Addr, Key} when is_tuple(Addr), is_binary(Key), byte_size(Key) =:= 32 ->
            case is_endpoint(Addr) of
                true  -> {ok, Addr};
                false -> {error, {bad_node_addr, Addr}}
            end;
        {undefined, Key} when is_binary(Key), byte_size(Key) =:= 32 ->
            {error, node_addr_required_for_keyed_node};
        {_Addr, _BadKey} ->
            {error, node_pubkey_required}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% The connection authority is created here. Ordinary targets resolve through
%% the shared cache; pinned and identity-discovery targets carry an explicit endpoint.
handle_cast({open_link_pinned, NodeKey, Endpoint, Channel, ReplyTo}, State) ->
    case ensure_pinned_conn(NodeKey, Endpoint, State) of
        {ok, ConnPid, State1} ->
            quod_conn:open_link(ConnPid, Channel, ReplyTo),
            {noreply, State1};
        error ->
            directory_link_error(ReplyTo, NodeKey, Channel),
            {noreply, State}
    end;
handle_cast(
  {open_link_pinned_lease, NodeKey, Endpoint, Channel, Lease}, State) ->
    case ensure_pinned_conn(NodeKey, Endpoint, State) of
        {ok, ConnPid, State1} ->
            quod_conn:open_link_lease(ConnPid, Channel, Lease),
            {noreply, State1};
        error ->
            directory_link_error(Lease, NodeKey, Channel),
            {noreply, State}
    end;
handle_cast(
  {release_link_pinned, NodeKey, Endpoint, Channel, Lease},
  State = #state{conns = Conns}) ->
    ConnKey = {directory_pinned, NodeKey, Endpoint},
    case {is_endpoint(Endpoint), maps:get(ConnKey, Conns, undefined)} of
        {true, ConnPid} when is_pid(ConnPid) ->
            quod_conn:release_link(ConnPid, Channel, Lease);
        _ ->
            ok
    end,
    {noreply, State};
handle_cast({send_pinned, NodeKey, Endpoint, Channel, Frame}, State)
  when is_binary(Frame) ->
    case ensure_pinned_conn(NodeKey, Endpoint, State) of
        {ok, ConnPid, State1} ->
            quod_conn:send(ConnPid, Channel, Frame),
            {noreply, State1};
        error ->
            {noreply, State}
    end;
handle_cast({send_pinned, _NodeKey, _Endpoint, _Channel, _Frame}, State) ->
    {noreply, State};
handle_cast({open_link_identified, Endpoint, Channel, ReplyTo}, State) ->
    case is_endpoint(Endpoint) of
        true ->
            ConnKey = {identified_endpoint, Endpoint},
            Policy = #{expected_peer => any, learn_hint => no_learn},
            {ConnPid, State1} =
                ensure_conn(ConnKey, Endpoint, Endpoint, Policy, State),
            quod_conn:open_link(ConnPid, Channel, ReplyTo),
            {noreply, State1};
        false ->
            directory_link_error(ReplyTo, Endpoint, Channel),
            {noreply, State}
    end;
handle_cast({open_link, Target, Channel, ReplyTo}, State) ->
    case resolve(Target) of
        {ok, Endpoint} ->
            Policy = ordinary_identity_policy(Target),
            {ConnPid, State1} = ensure_conn(Target, Target, Endpoint, Policy, State),
            quod_conn:open_link(ConnPid, Channel, ReplyTo),
            {noreply, State1};
        error ->
            logger:debug("quod: open_link target ~p unresolved/non-dialable", [Target]),
            ordinary_link_error(ReplyTo, Target, Channel),
            {noreply, State}
    end;
%% fire-and-forget send: resolve + ensure the connection (dialing on demand), then hand the frame to the
%% conn, which sends on a live link or buffers until one is up. An unresolved target is dropped silently
%% (no waiter to notify — the caller retries), unlike open_link which owes its caller a link_error.
handle_cast({send, Target, Channel, Frame}, State) ->
    case resolve(Target) of
        {ok, Endpoint} ->
            Policy = ordinary_identity_policy(Target),
            {ConnPid, State1} = ensure_conn(Target, Target, Endpoint, Policy, State),
            quod_conn:send(ConnPid, Channel, Frame),
            {noreply, State1};
        error ->
            logger:debug("quod: send target ~p unresolved/non-dialable — dropped", [Target]),
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({conn_terminal, Pid, Ref}, State = #state{conns = Conns})
  when is_pid(Pid), is_reference(Ref) ->
    %% Remove only mappings still owned by this exact connection generation.
    %% ACK after removal; all earlier owner->conn opens are ordered before it,
    %% while any later API call necessarily creates/selects the replacement.
    Conns1 = maps:filter(fun(_, ConnPid) -> ConnPid =/= Pid end, Conns),
    Pid ! {conn_terminal_ack, self(), Ref},
    {noreply, State#state{conns = Conns1}};
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
%% `ConnKey` preserves the caller's trust mode: an ordinary target, an exact
%% pinned key+endpoint, or an identity-discovery endpoint. The dial always uses
%% `Endpoint`.
ensure_conn(ConnKey, Peer, Endpoint, Policy, State = #state{conns = Conns}) ->
    case maps:get(ConnKey, Conns, undefined) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true  -> {Pid, State};
                false -> start_conn(ConnKey, Peer, Endpoint, Policy, State)
            end;
        undefined ->
            start_conn(ConnKey, Peer, Endpoint, Policy, State)
    end.

ensure_pinned_conn(NodeKey, Endpoint, State)
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
    case is_endpoint(Endpoint) of
        true ->
            ConnKey = {directory_pinned, NodeKey, Endpoint},
            Policy = #{expected_peer => NodeKey, learn_hint => no_learn},
            {ConnPid, State1} =
                ensure_conn(ConnKey, NodeKey, Endpoint, Policy, State),
            {ok, ConnPid, State1};
        false ->
            error
    end;
ensure_pinned_conn(_NodeKey, _Endpoint, _State) ->
    error.

start_conn(ConnKey, Peer, {Host, Port}, Policy,
           State = #state{conns = Conns, self = Self, alpn = ALPN,
                          cert = Cert, key = Key}) ->
    Pid =
        quod_conn:start_outbound(
          Host, Port, Peer, Self, ALPN, Cert, Key, Policy, self()),
    _ = erlang:monitor(process, Pid),
    {Pid, State#state{conns = maps:put(ConnKey, Pid, Conns)}}.

directory_link_error({ReplyTo, Ref}, Peer, Channel) ->
    ReplyTo ! {link_error, Ref, Peer, Channel},
    ok.

ordinary_link_error({ReplyTo, Ref}, Peer, Channel) ->
    directory_link_error({ReplyTo, Ref}, Peer, Channel);
ordinary_link_error(ReplyTo, Peer, Channel) when is_pid(ReplyTo) ->
    ReplyTo ! {link_error, Peer, Channel},
    ok.

ordinary_identity_policy(Target)
  when is_binary(Target), byte_size(Target) =:= 32 ->
    #{expected_peer => Target, learn_hint => learn};
ordinary_identity_policy(_Target) ->
    #{expected_peer => undefined, learn_hint => learn}.

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

%% short, log-readable id: a real pubkey via quod_identity, an address shown as-is.
id_str(Pubkey) when is_binary(Pubkey) -> quod_identity:short(Pubkey);
id_str(Other)                         -> io_lib:format("~p", [Other]).

%% The node's transport cert+key, as `{ok, {Cert, Key}}` or a clean `{error, Reason}`.
%% Production: the per-node Ed25519 identity, set in the app env by `quod_app:apply_identity`
%% (DER cert + opaque key handle, unwrapped only at the TLS call). Explicit
%% PEM-configured boots fall back to the `certfile`/`keyfile` pair — a missing/empty
%% file is reported, not badmatched, so
%% `init/1` can `{stop, _}` with a readable reason instead of crashing the transport at boot.
identity_certkey() ->
    %% get_env yields the bare atom `undefined` when unset, so an absent key misses the
    %% `{ok, _}` pattern and falls to the PEM fallback (no guard needed).
    case {application:get_env(quod, identity_cert), application:get_env(quod, identity_key)} of
        {{ok, Cert}, {ok, Key}} ->
            {ok, {Cert, Key}};
        _ ->
            load_pem_pair(env(certfile, "priv/certs/cert.pem"),
                          env(keyfile, "priv/certs/key.pem"))
    end.

%% Both halves of the fallback pair, tagging the offending file on the first failure.
load_pem_pair(CertFile, KeyFile) ->
    case load_cert(CertFile) of
        {ok, Cert} ->
            case load_key(KeyFile) of
                {ok, Key}    -> {ok, {Cert, Key}};
                {error, KR}  -> {error, {keyfile, KeyFile, KR}}
            end;
        {error, CR} ->
            {error, {certfile, CertFile, CR}}
    end.

%% certs: load the PEM file -> DER cert / decoded key term (what `quic` expects). A missing
%% file returns `file:read_file`'s error (e.g. `enoent`); a PEM with no matching entry returns
%% a named reason — never a badmatch.
load_cert(File) ->
    case file:read_file(File) of
        {ok, Pem} ->
            case [D || {'Certificate', D, _} <- public_key:pem_decode(Pem)] of
                [Der | _] -> {ok, Der};
                []        -> {error, no_certificate_in_pem}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

load_key(File) ->
    case file:read_file(File) of
        {ok, Pem} ->
            Keys = [E || {T, _, _} = E <- public_key:pem_decode(Pem), is_private_key_type(T)],
            case Keys of
                %% only an unencrypted entry is decodable; `der_decode` still THROWS on
                %% truncated/garbage DER, so guard it — an unreadable key must surface as a
                %% clean `{error, _}` (and hence `{stop, _}` in init/1), never a boot crash.
                [{Type, Der, not_encrypted} | _] ->
                    try {ok, public_key:der_decode(Type, Der)}
                    catch _:_ -> {error, {undecodable_private_key, Type}}
                    end;
                [{Type, _Der, _Enc} | _] ->
                    {error, {encrypted_private_key, Type}};
                [] ->
                    {error, no_private_key_in_pem}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% PEM entry tags that carry an actual private key (excludes 'Certificate' AND parameter
%% blocks like 'EcpkParameters'/'DHParameter' that a `T =/= 'Certificate'` filter would
%% wrongly select as the key in a multi-entry file).
is_private_key_type('RSAPrivateKey')   -> true;
is_private_key_type('DSAPrivateKey')   -> true;
is_private_key_type('ECPrivateKey')    -> true;
is_private_key_type('PrivateKeyInfo')  -> true;   %% PKCS#8 (the default key.pem)
is_private_key_type(_)                 -> false.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L);
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8).

env(Key, Default) -> application:get_env(quod, Key, Default).

-doc """
QUIC liveness options — `idle_timeout` (drop a peer we haven't heard from) + `keep_alive_interval`
(PING an otherwise-quiet link) — for fast dead-peer detection. Read from config (`node.idle_timeout_ms`
/ `node.keepalive_ms`, bridged to app-env by `m:quod_app`). The SINGLE source shared by the server
listener here and `quod_conn`'s dial, so both directions detect symmetrically (this quic build enforces
each side's own idle timeout rather than negotiating the RFC min). Detection ≈ the two summed (~2.5s).
""".
-spec liveness_opts() -> #{idle_timeout := pos_integer(), keep_alive_interval := pos_integer()}.
liveness_opts() ->
    #{idle_timeout        => env(quic_idle_timeout_ms, 2000),
      keep_alive_interval => env(quic_keepalive_ms, 500)}.
