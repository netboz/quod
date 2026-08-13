-module(quod_client_auth).
-moduledoc """
Bounded, node-local proof-of-key challenges and sessions for the browser client.

This service proves that a browser controls an Ed25519 key and issues an
opaque, short-lived session bound to that key. It neither creates an ontology
nor authorizes a world command; typed command ingress owns those later steps.

Challenges are held only in memory, expire quickly, and are consumed before
signature verification. A captured completion therefore cannot be replayed.

Two properties are worth stating because they shaped the code:

- **Signature verification runs in the caller**, not in this process. Only
  taking and binding need to be serialized; verifying inside the server would
  put every login's crypto on the one mailbox that also answers session lookups.
- **A challenge is never spent for nothing.** Capacity is checked before the
  challenge is consumed, so a node at its session ceiling refuses the login
  outright instead of destroying a single-use challenge the client must then
  re-obtain.

Every local validity and window comparison uses the monotonic clock. Only the
expiry a browser signs is wall-clock, because both ends must read it the same.
""".

-behaviour(gen_server).

-export([start_link/0, issue_challenge/3, complete_challenge/2, session/1,
         reserve_registration/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([start_link/1]).
-endif.

-define(TTL_MS, 60000).
-define(MAX_CHALLENGES, 256).
-define(SESSION_TTL_MS, 600000).
-define(MAX_SESSIONS, 256).
-define(PRUNE_INTERVAL_MS, 30000).
-define(WINDOW_MS, 60000).
%% Logins are cheap and common, registrations are durable and rare, so they get
%% separate budgets rather than one shared number.
-define(CHALLENGE_LIMIT,
        #{window_ms => ?WINDOW_MS, max_total => 256, max_per_key => 16,
          max_keys => 256}).
-define(REGISTRATION_LIMIT,
        #{window_ms => ?WINDOW_MS, max_total => 64, max_per_key => 4,
          max_keys => 256}).

-record(s, {network_id :: binary() | undefined,
            node_key :: binary() | undefined,
            challenges = #{} :: #{binary() => map()},
            sessions = #{} :: #{binary() => map()},
            ttl_ms :: pos_integer(),
            max_challenges :: pos_integer(),
            session_ttl_ms :: pos_integer(),
            max_sessions :: pos_integer(),
            challenge_rate :: quod_rate:limiter(),
            registration_rate :: quod_rate:limiter()}).

start_link() ->
    case application:get_env(quod, client_enabled, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []);
        _ -> ignore
    end.

-ifdef(TEST).
-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) when is_map(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).
-endif.

-doc """
Issue one short-lived challenge for `PublicKey`.

`Peer` is the requesting address, charged against the per-peer login budget:
issuing is unauthenticated, so without it one address could hold every challenge
slot on the node and lock everyone else out of logging in.
""".
-spec issue_challenge(binary(), binary(), term()) -> {ok, map()} | {error, term()}.
issue_challenge(PublicKey, ClientNonce, Peer) ->
    call({issue, PublicKey, ClientNonce, Peer}).

-doc """
Complete a challenge and open a session.

The challenge is taken here and verified in this (caller) process; only the
take and the bind touch the server.
""".
-spec complete_challenge(binary(), binary()) -> {ok, map()} | {error, term()}.
complete_challenge(ChallengeId, Signature) ->
    case call({take_challenge, ChallengeId}) of
        {ok, Challenge} -> verify_taken(ChallengeId, Signature, Challenge);
        {error, _} = Error -> Error
    end.

-doc "Return the still-valid public session binding for a typed ingress command.".
-spec session(binary()) -> {ok, map()} | {error, invalid_session | client_auth_unavailable}.
session(SessionId) ->
    call({session, SessionId}).

-doc """
Charge one open-registration attempt for `Peer`.

Called only once a registration request has proved its own signature, so junk
cannot spend the budget that protects durable ontology creation.
""".
-spec reserve_registration(term()) -> ok | {error, term()}.
reserve_registration(Peer) ->
    call({reserve_registration, Peer}).

call(Request) ->
    try gen_server:call(?MODULE, Request, 5000)
    catch exit:_ -> {error, client_auth_unavailable}
    end.

init(Options) ->
    schedule_prune(),
    {ok, #s{network_id = maps:get(network_id, Options, undefined),
            node_key = maps:get(node_key, Options, undefined),
            ttl_ms = maps:get(ttl_ms, Options, ?TTL_MS),
            max_challenges = maps:get(max_challenges, Options, ?MAX_CHALLENGES),
            session_ttl_ms = maps:get(session_ttl_ms, Options, ?SESSION_TTL_MS),
            max_sessions = maps:get(max_sessions, Options, ?MAX_SESSIONS),
            challenge_rate = quod_rate:new(
                               maps:get(challenge_limit, Options,
                                        ?CHALLENGE_LIMIT)),
            registration_rate = quod_rate:new(
                                  maps:get(registration_limit, Options,
                                           ?REGISTRATION_LIMIT))}}.

handle_call({issue, PublicKey, ClientNonce, Peer}, _From, S) ->
    reply(issue(PublicKey, ClientNonce, Peer, S));
handle_call({take_challenge, ChallengeId}, _From, S) ->
    reply(take_challenge(ChallengeId, S));
handle_call({bind_session, Identity}, _From, S) ->
    reply(bind_session(Identity, S));
handle_call({session, SessionId}, _From, S) ->
    reply(lookup_session(SessionId, S));
handle_call({reserve_registration, Peer}, _From, S) ->
    reply(charge(#s.registration_rate, Peer, client_registration, S));
handle_call(_Request, _From, S) ->
    {reply, {error, invalid_request}, S}.

handle_cast(_Message, S) -> {noreply, S}.

handle_info(prune, S) ->
    schedule_prune(),
    {noreply, prune_expired(quod_time:mono_ms(), S)};
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, _S) -> ok.

reply({Reply, S}) -> {reply, Reply, S}.

schedule_prune() -> erlang:send_after(?PRUNE_INTERVAL_MS, self(), prune).

%% ======================================================================
%% challenges
%% ======================================================================

issue(PublicKey, ClientNonce, Peer, S0) ->
    case {quod_user:identity(PublicKey), valid_nonce(ClientNonce),
          network_and_node(S0)} of
        {{error, invalid_public_key}, _, _} ->
            {{error, invalid_public_key}, S0};
        {_, false, _} ->
            {{error, invalid_client_nonce}, S0};
        {_, _, {error, _} = Error} ->
            {Error, S0};
        {{ok, _}, true, {ok, NetworkId, NodeKey}} ->
            %% A full challenge table is this node's availability condition,
            %% not a failed attempt by this caller. Check it before charging
            %% the caller's rate budget so a burst cannot lock out a user.
            case challenges_full(S0) of
                true -> {{error, client_auth_busy}, S0};
                false ->
                    case charge(#s.challenge_rate, Peer, client_auth, S0) of
                        {ok, S} -> issue_charged(PublicKey, ClientNonce, NetworkId,
                                                 NodeKey, S);
                        Refused -> Refused
                    end
            end
    end.

issue_charged(PublicKey, ClientNonce, NetworkId, NodeKey,
              S = #s{challenges = Challenges, ttl_ms = Ttl}) ->
    ChallengeId = crypto:strong_rand_bytes(16),
    ServerNonce = crypto:strong_rand_bytes(32),
    %% The browser signs this wall-clock expiry, so both ends must read the same
    %% number; the local liveness check below uses the monotonic deadline.
    ExpiresMs = quod_time:now_ms() + Ttl,
    Challenge = #{network_id => NetworkId,
                  node_key => NodeKey,
                  public_key => PublicKey,
                  client_nonce => ClientNonce,
                  server_nonce => ServerNonce,
                  expires_ms => ExpiresMs,
                  deadline => quod_time:mono_ms() + Ttl},
    Reply = #{challenge_id => ChallengeId,
              server_nonce => ServerNonce,
              expires_ms => ExpiresMs,
              node_key => NodeKey,
              network_id => NetworkId},
    {{ok, Reply}, S#s{challenges = Challenges#{ChallengeId => Challenge}}}.

challenges_full(#s{challenges = Challenges, max_challenges = Max}) ->
    map_size(Challenges) >= Max.

%% Capacity is tested BEFORE the take: a challenge is single-use, so consuming
%% one only to refuse the session would cost the client a full round trip for
%% nothing.
take_challenge(ChallengeId, S = #s{challenges = Challenges})
  when is_binary(ChallengeId), byte_size(ChallengeId) =:= 16 ->
    case sessions_full(S) of
        true ->
            {{error, client_session_busy}, S};
        false ->
            case maps:take(ChallengeId, Challenges) of
                error ->
                    {{error, invalid_challenge}, S};
                {Challenge, Remaining} ->
                    %% Consumed regardless of what the caller's verification
                    %% concludes: a bad signature must not leave a challenge
                    %% behind to be guessed at again.
                    S1 = S#s{challenges = Remaining},
                    case live(Challenge) of
                        true -> {{ok, Challenge}, S1};
                        false -> {{error, invalid_challenge}, S1}
                    end
            end
    end;
take_challenge(_ChallengeId, S) ->
    {{error, invalid_challenge}, S}.

verify_taken(ChallengeId, Signature,
             #{network_id := NetworkId, node_key := NodeKey,
               public_key := PublicKey, client_nonce := ClientNonce,
               server_nonce := ServerNonce, expires_ms := ExpiresMs}) ->
    case quod_user:verify_challenge(
           NetworkId, NodeKey, ChallengeId, PublicKey, ClientNonce,
           ServerNonce, {ExpiresMs, Signature}) of
        ok ->
            {ok, Identity} = quod_user:identity(PublicKey),
            call({bind_session, Identity});
        {error, _} = Error -> Error
    end.

%% ======================================================================
%% sessions
%% ======================================================================

bind_session(Identity, S = #s{sessions = Sessions, session_ttl_ms = Ttl}) ->
    case sessions_full(S) of
        true ->
            {{error, client_session_busy}, S};
        false ->
            SessionId = crypto:strong_rand_bytes(32),
            ExpiresMs = quod_time:now_ms() + Ttl,
            %% Stored minimally: the key is the whole binding, and user id,
            %% namespace and principal are all derivable from it. Keeping one
            %% copy means they cannot drift apart.
            Session = #{public_key => maps:get(public_key, Identity),
                        expires_ms => ExpiresMs,
                        deadline => quod_time:mono_ms() + Ttl},
            {{ok, public_session(SessionId, Session, Identity)},
             S#s{sessions = Sessions#{SessionId => Session}}}
    end.

lookup_session(SessionId, S = #s{sessions = Sessions}) ->
    case maps:find(SessionId, Sessions) of
        {ok, Session} ->
            case live(Session) of
                true -> {{ok, session_binding(SessionId, Session)}, S};
                %% Expired but not yet pruned — drop it now rather than leave it
                %% to be found again by the next lookup.
                false -> {{error, invalid_session},
                          S#s{sessions = maps:remove(SessionId, Sessions)}}
            end;
        error -> {{error, invalid_session}, S}
    end.

session_binding(SessionId, #{public_key := PublicKey} = Session) ->
    {ok, Identity} = quod_user:identity(PublicKey),
    public_session(SessionId, Session, Identity).

public_session(SessionId, #{public_key := PublicKey, expires_ms := ExpiresMs},
               #{user_id := UserId, namespace := Namespace}) ->
    {ok, Principal} = quod_user:principal(PublicKey),
    #{session_id => SessionId,
      expires_ms => ExpiresMs,
      public_key => PublicKey,
      principal => Principal,
      user_id => UserId,
      namespace => Namespace}.

sessions_full(#s{sessions = Sessions, max_sessions = Max}) ->
    map_size(Sessions) >= Max.

%% ======================================================================
%% plumbing
%% ======================================================================

charge(Field, Peer, Tag, S) ->
    case quod_rate:allow(Peer, quod_time:mono_ms(), element(Field, S)) of
        {ok, Rate} -> {ok, setelement(Field, S, Rate)};
        {busy, Rate} ->
            {{error, tagged(Tag, busy)}, setelement(Field, S, Rate)};
        {rate_limited, Rate} ->
            {{error, tagged(Tag, rate_limited)}, setelement(Field, S, Rate)}
    end.

tagged(client_auth, busy) -> client_auth_busy;
tagged(client_auth, rate_limited) -> client_auth_rate_limited;
tagged(client_registration, busy) -> client_registration_busy;
tagged(client_registration, rate_limited) -> client_registration_rate_limited.

network_and_node(#s{network_id = Network0, node_key = Node0}) ->
    Network = case Network0 of
                  <<_:256>> -> {ok, Network0};
                  _ -> quod_ontology:genesis_anchor(quod_ontology:root_ns())
              end,
    Node = case Node0 of
               <<_:256>> -> {ok, Node0};
               _ -> application:get_env(quod, node_pubkey)
           end,
    case {Network, Node} of
        {{ok, <<_:256>> = NetworkId}, {ok, <<_:256>> = NodeKey}} ->
            {ok, NetworkId, NodeKey};
        _ ->
            {error, client_auth_unavailable}
    end.

%% A periodic sweep, not a per-request one: at full caps, rebuilding both tables
%% on every lookup would put a few hundred entries of copying in front of each
%% request. Lookups still check the one entry they touch, so nothing expired is
%% ever honoured between sweeps.
prune_expired(Now, S = #s{challenges = Challenges, sessions = Sessions}) ->
    S#s{challenges = drop_expired(Now, Challenges),
        sessions = drop_expired(Now, Sessions)}.

drop_expired(Now, Map) ->
    maps:filter(fun(_Id, #{deadline := Deadline}) -> Deadline > Now end, Map).

live(#{deadline := Deadline}) -> Deadline > quod_time:mono_ms().

valid_nonce(<<_:256>>) -> true;
valid_nonce(_) -> false.
