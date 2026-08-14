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

The cumulative client-vocabulary ceiling is tied to the VM lifetime, just as
the atom table is.  A baseline atom count is retained in `persistent_term`
across auth-owner restarts; the owner then conservatively counts all atom-table
growth since that baseline.  Restarting this process therefore cannot reset the
ceiling, while restarting the VM naturally resets both atoms and the baseline.
""".

-behaviour(gen_server).

-export([start_link/0, issue_challenge/3, complete_challenge/2, session/1,
         reserve_registration/1, admit_goal/2, materialize_goal/3]).
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

-include("quod_client_goal_limits.hrl").

-define(GOAL_USER_LIMIT,
        #{window_ms => ?QUOD_CLIENT_GOAL_RATE_WINDOW_MS,
          max_total => ?QUOD_CLIENT_GOAL_RATE_TOTAL,
          max_per_key => ?QUOD_CLIENT_GOAL_RATE_PER_USER,
          max_keys => ?QUOD_CLIENT_GOAL_RATE_KEYS}).
-define(GOAL_PEER_LIMIT,
        #{window_ms => ?QUOD_CLIENT_GOAL_RATE_WINDOW_MS,
          max_total => ?QUOD_CLIENT_GOAL_RATE_TOTAL,
          max_per_key => ?QUOD_CLIENT_GOAL_RATE_PER_PEER,
          max_keys => ?QUOD_CLIENT_GOAL_RATE_KEYS}).
-define(SYMBOL_USER_LIMIT,
        #{window_ms => ?QUOD_CLIENT_GOAL_RATE_WINDOW_MS,
          max_total => ?QUOD_CLIENT_SYMBOL_RATE_TOTAL,
          max_per_key => ?QUOD_CLIENT_SYMBOL_RATE_PER_USER,
          max_keys => ?QUOD_CLIENT_GOAL_RATE_KEYS}).
-define(SYMBOL_PEER_LIMIT,
        #{window_ms => ?QUOD_CLIENT_GOAL_RATE_WINDOW_MS,
          max_total => ?QUOD_CLIENT_SYMBOL_RATE_TOTAL,
          max_per_key => ?QUOD_CLIENT_SYMBOL_RATE_PER_PEER,
          max_keys => ?QUOD_CLIENT_GOAL_RATE_KEYS}).

-record(s, {network_id :: binary() | undefined,
            node_key :: binary() | undefined,
            challenges = #{} :: #{binary() => map()},
            sessions = #{} :: #{binary() => map()},
            ttl_ms :: pos_integer(),
            max_challenges :: pos_integer(),
            session_ttl_ms :: pos_integer(),
            max_sessions :: pos_integer(),
            challenge_rate :: quod_rate:limiter(),
            registration_rate :: quod_rate:limiter(),
            goal_user_rate :: quod_rate:limiter(),
            goal_peer_rate :: quod_rate:limiter(),
            symbol_user_rate :: quod_rate:limiter(),
            symbol_peer_rate :: quod_rate:limiter(),
            atom_baseline :: non_neg_integer(),
            max_materialized_atoms :: non_neg_integer()}).

-define(ATOM_BASELINE_KEY, {?MODULE, atom_baseline}).

start_link() ->
    case application:get_env(quod, client_enabled, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []);
        _ -> ignore
    end.

-ifdef(TEST).
-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) when is_map(Options) ->
    %% Unit tests normally want an isolated baseline. A test that exercises a
    %% restart passes the same explicit baseline to both owners.
    TestOptions = case maps:is_key(atom_baseline, Options) of
                      true -> Options;
                      false -> Options#{atom_baseline => isolated}
                  end,
    gen_server:start_link({local, ?MODULE}, ?MODULE, TestOptions, []).
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

-doc "Resolve a live session and atomically charge its user and peer goal budgets.".
-spec admit_goal(binary(), term()) -> {ok, map()} | {error, term()}.
admit_goal(SessionId, Peer) ->
    call({admit_goal, SessionId, Peer}).

-doc "Materialize one already-verified goal under exact user, peer and VM budgets.".
-spec materialize_goal(<<_:256>>, term(), term()) ->
          {ok, term()} | {error, term()}.
materialize_goal(PublicKey, Peer, Goal) ->
    call({materialize_goal, PublicKey, Peer, Goal}).

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
                                           ?REGISTRATION_LIMIT)),
            goal_user_rate = quod_rate:new(
                               maps:get(goal_user_limit, Options,
                                        ?GOAL_USER_LIMIT)),
            goal_peer_rate = quod_rate:new(
                               maps:get(goal_peer_limit, Options,
                                        ?GOAL_PEER_LIMIT)),
            symbol_user_rate = quod_rate:new(
                                 maps:get(symbol_user_limit, Options,
                                          ?SYMBOL_USER_LIMIT)),
            symbol_peer_rate = quod_rate:new(
                                 maps:get(symbol_peer_limit, Options,
                                          ?SYMBOL_PEER_LIMIT)),
            atom_baseline = atom_baseline(Options),
            max_materialized_atoms =
                maps:get(max_materialized_atoms, Options,
                         ?QUOD_CLIENT_MAX_CUMULATIVE_NEW_ATOMS)}}.

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
handle_call({admit_goal, SessionId, Peer}, _From, S) ->
    reply(admit_goal_request(SessionId, Peer, S));
handle_call({materialize_goal, PublicKey, Peer, Goal}, _From, S) ->
    reply(materialize_verified_goal(PublicKey, Peer, Goal, S));
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

%% ======================================================================
%% signed goals
%% ======================================================================

admit_goal_request(SessionId, Peer, S0) ->
    case lookup_session(SessionId, S0) of
        {{ok, #{public_key := PublicKey} = Session}, S1} ->
            case charge_pair(
                   #s.goal_user_rate, PublicKey,
                   #s.goal_peer_rate, Peer, S1) of
                {ok, S2} -> {{ok, Session}, S2};
                {{error, _} = Error, S2} -> {Error, S2}
            end;
        {{error, _} = Error, S1} ->
            {Error, S1}
    end.

materialize_verified_goal(<<_:256>> = PublicKey, Peer, Goal, S0) ->
    case quod_wire_term:goal_symbol_names(Goal) of
        {ok, Names} ->
            NewNames = [Name || Name <- Names, not existing_atom(Name)],
            materialize_new_symbols(PublicKey, Peer, Goal, length(NewNames), S0);
        {error, _} ->
            {{error, invalid_goal}, S0}
    end;
materialize_verified_goal(_PublicKey, _Peer, _Goal, S) ->
    {{error, invalid_user_principal}, S}.

materialize_new_symbols(_PublicKey, _Peer, Goal, 0, S) ->
    case quod_wire_term:materialize_goal_symbols(Goal) of
        {ok, Materialized} -> {{ok, Materialized}, S};
        {error, Reason} -> {{error, Reason}, S}
    end;
materialize_new_symbols(PublicKey, Peer, Goal, Count,
                        #s{atom_baseline = Baseline,
                           max_materialized_atoms = Max} = S0)
  when Count > 0 ->
    Used = max(0, erlang:system_info(atom_count) - Baseline),
    case Used + Count =< Max of
        false ->
            {{error, client_symbol_budget_exhausted}, S0};
        true ->
            case charge_pair_many(
                   #s.symbol_user_rate, PublicKey,
                   #s.symbol_peer_rate, Peer, Count, S0) of
                {{error, _} = Error, S1} ->
                    {Error, S1};
                {ok, S1} ->
                    %% The owner serializes client vocabulary allocation.  The
                    %% existing materializer still enforces per-request and VM
                    %% headroom limits shared with every other wire boundary.
                    case quod_wire_term:materialize_goal_symbols(Goal) of
                        {ok, Materialized} ->
                            {{ok, Materialized}, S1};
                        {error, Reason} ->
                            {{error, Reason}, S1}
                    end
            end
    end.

charge_pair(FirstField, FirstKey, SecondField, SecondKey, S) ->
    charge_pair_many(FirstField, FirstKey, SecondField, SecondKey, 1, S).

charge_pair_many(FirstField, FirstKey, SecondField, SecondKey, Count, S)
  when is_integer(Count), Count > 0 ->
    Now = quod_time:mono_ms(),
    case allow_many(FirstKey, Count, Now, element(FirstField, S)) of
        {ok, FirstRate} ->
            case allow_many(SecondKey, Count, Now, element(SecondField, S)) of
                {ok, SecondRate} ->
                    {ok, setelement(SecondField,
                                    setelement(FirstField, S, FirstRate),
                                    SecondRate)};
                {Reason, _SecondRate} ->
                    %% The operation needs both budgets.  A refusal by either
                    %% side commits neither provisional charge.
                    {{error, goal_rate_error(Reason)}, S}
            end;
        {Reason, _FirstRate} ->
            {{error, goal_rate_error(Reason)}, S}
    end.

allow_many(_Key, 0, _Now, Rate) ->
    {ok, Rate};
allow_many(Key, Remaining, Now, Rate0) ->
    case quod_rate:allow(Key, Now, Rate0) of
        {ok, Rate1} -> allow_many(Key, Remaining - 1, Now, Rate1);
        {Reason, Rate1} -> {Reason, Rate1}
    end.

goal_rate_error(busy) -> client_goal_busy;
goal_rate_error(rate_limited) -> client_goal_rate_limited.

existing_atom(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        _ -> true
    catch
        error:badarg -> false
    end.

atom_baseline(#{atom_baseline := Baseline})
  when is_integer(Baseline), Baseline >= 0 ->
    Baseline;
atom_baseline(#{atom_baseline := isolated}) ->
    erlang:system_info(atom_count);
atom_baseline(_Options) ->
    case persistent_term:get(?ATOM_BASELINE_KEY, undefined) of
        Baseline when is_integer(Baseline), Baseline >= 0 ->
            Baseline;
        undefined ->
            Baseline = erlang:system_info(atom_count),
            persistent_term:put(?ATOM_BASELINE_KEY, Baseline),
            Baseline
    end.

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
