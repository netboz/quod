-module(quod_client_auth).
-moduledoc """
Bounded, node-local proof-of-key challenges and sessions for the browser client.

This service proves that a browser controls an Ed25519 key and issues an
opaque, short-lived session bound to that key. It neither creates an ontology
nor authorizes a goal; signed-goal ingress owns those later steps.

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

-export([start_link/0, issue_challenge/3, complete_challenge/2,
         admit_goal/2, admit_forwarded_goal/2,
         materialize_goal/3, materialize_request/4,
         challenge_bytes/7, verify_challenge/7]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([start_link/1, session/1]).
-endif.

-define(TTL_MS, 60000).
-define(MAX_CHALLENGES, 256).
-define(SESSION_TTL_MS, 600000).
-define(MAX_SESSIONS, 256).
-define(PRUNE_INTERVAL_MS, 30000).
-include("quod_client_goal_limits.hrl").

-record(s, {network_id :: binary() | undefined,
            node_key :: binary() | undefined,
            challenges = #{} :: #{binary() => map()},
            sessions = #{} :: #{binary() => map()},
            ttl_ms :: pos_integer(),
            max_challenges :: pos_integer(),
            session_ttl_ms :: pos_integer(),
            max_sessions :: pos_integer(),
            challenge_rate :: none | quod_rate:limiter(),
            goal_signing_key_rate :: none | quod_rate:limiter(),
            goal_peer_rate :: none | quod_rate:limiter(),
            symbol_signing_key_rate :: none | quod_rate:limiter(),
            symbol_peer_rate :: none | quod_rate:limiter(),
            atom_baseline :: non_neg_integer(),
            max_materialized_atoms :: non_neg_integer()}).

-define(ATOM_BASELINE_KEY, {?MODULE, atom_baseline}).
-define(CHALLENGE_DOMAIN, <<"quod.agent.challenge.v1", 0>>).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

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

`Peer` is retained for an operator-enabled rate policy. By default there is no
per-peer request quota; the bounded challenge table is the normal protection.
An internet-facing deployment should explicitly configure `challenge_limit`
under `client_rate_limits`; a trusted network may rely on the table cap.
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

-ifdef(TEST).
-doc "Return the still-valid public session binding.".
-spec session(binary()) -> {ok, map()} | {error, invalid_session | client_auth_unavailable}.
session(SessionId) ->
    call({session, SessionId}).
-endif.

-doc "Resolve a live session and atomically charge its signing-key and peer budgets.".
-spec admit_goal(binary(), term()) -> {ok, map()} | {error, term()}.
admit_goal(SessionId, Peer) ->
    call({admit_goal, SessionId, Peer}).

-doc "Charge one verified signing-key request forwarded by an authenticated node.".
-spec admit_forwarded_goal(<<_:256>>, <<_:256>>) ->
          ok | {error, term()}.
admit_forwarded_goal(<<_:256>> = PublicKey, <<_:256>> = ForwarderKey) ->
    call({admit_forwarded_goal, PublicKey, ForwarderKey});
admit_forwarded_goal(_PublicKey, _ForwarderKey) ->
    {error, invalid_signing_key}.

-doc "Materialize one already-verified goal under exact signing-key, peer and VM budgets.".
-spec materialize_goal(<<_:256>>, term(), term()) ->
          {ok, term()} | {error, term()}.
materialize_goal(PublicKey, Peer, Goal) ->
    call({materialize_goal, PublicKey, Peer, Goal}).

-doc "Materialize one verified agent reference and goal under the shared atom budget.".
-spec materialize_request(<<_:256>>, term(), binary(), term()) ->
          {ok, term(), term()} | {error, term()}.
materialize_request(PublicKey, Peer, AgentRefBlob, Goal) ->
    case quod_agent_ref:decode(AgentRefBlob) of
        {ok, #{reference := AgentRef}} ->
            case call(
                   {materialize_request, PublicKey, Peer, AgentRef, Goal}) of
                {ok, {MaterializedAgentRef, MaterializedGoal}} ->
                    {ok, MaterializedAgentRef, MaterializedGoal};
                {error, _} = Error -> Error
            end;
        {error, _} -> {error, invalid_agent_reference}
    end.

call(Request) ->
    try gen_server:call(?MODULE, Request, 5000)
    catch exit:_ -> {error, client_auth_unavailable}
    end.

init(Options) ->
    schedule_prune(),
    RateLimits = configured_rate_limits(),
    {ok, #s{network_id = maps:get(network_id, Options, undefined),
            node_key = maps:get(node_key, Options, undefined),
            ttl_ms = maps:get(ttl_ms, Options, ?TTL_MS),
            max_challenges = maps:get(max_challenges, Options, ?MAX_CHALLENGES),
            session_ttl_ms = maps:get(session_ttl_ms, Options, ?SESSION_TTL_MS),
            max_sessions = maps:get(max_sessions, Options, ?MAX_SESSIONS),
            challenge_rate = optional_rate(
                               rate_limit(challenge_limit, Options, RateLimits)),
            goal_signing_key_rate = optional_rate(
                                      rate_limit(goal_signing_key_limit,
                                                 Options, RateLimits)),
            goal_peer_rate = optional_rate(
                               rate_limit(goal_peer_limit, Options, RateLimits)),
            symbol_signing_key_rate = optional_rate(
                                        rate_limit(symbol_signing_key_limit,
                                                   Options, RateLimits)),
            symbol_peer_rate = optional_rate(
                                 rate_limit(symbol_peer_limit, Options, RateLimits)),
            atom_baseline = atom_baseline(Options),
            max_materialized_atoms =
                maps:get(max_materialized_atoms, Options,
                         ?QUOD_CLIENT_MAX_CUMULATIVE_NEW_ATOMS)}}.

%% Rate policy is operator-controlled and opt-in. Normal client traffic is
%% limited only by the existing bounded queues and workers. Tests pass an
%% explicit per-owner option so they do not depend on application state.
configured_rate_limits() ->
    case application:get_env(quod, client_rate_limits, #{}) of
        Limits when is_map(Limits) -> Limits;
        Invalid -> error({invalid_client_rate_limits, Invalid})
    end.

rate_limit(Name, Options, Config) ->
    maps:get(Name, Options, maps:get(Name, Config, none)).

optional_rate(none) -> none;
optional_rate(Config) when is_map(Config) -> quod_rate:new(Config);
optional_rate(Invalid) -> error({invalid_client_rate_limit, Invalid}).

handle_call({issue, PublicKey, ClientNonce, Peer}, _From, S) ->
    reply(issue(PublicKey, ClientNonce, Peer, S));
handle_call({take_challenge, ChallengeId}, _From, S) ->
    reply(take_challenge(ChallengeId, S));
handle_call({bind_session, Identity}, _From, S) ->
    reply(bind_session(Identity, S));
handle_call({session, SessionId}, _From, S) ->
    reply(lookup_session(SessionId, S));
handle_call({admit_goal, SessionId, Peer}, _From, S) ->
    reply(admit_goal_request(SessionId, Peer, S));
handle_call({admit_forwarded_goal, PublicKey, ForwarderKey}, _From, S) ->
    reply(admit_forwarded_goal_request(PublicKey, ForwarderKey, S));
handle_call({materialize_goal, PublicKey, Peer, Goal}, _From, S) ->
    reply(materialize_verified_goal(PublicKey, Peer, Goal, S));
handle_call({materialize_request, PublicKey, Peer, AgentRef, Goal}, _From, S) ->
    reply(materialize_verified_request(PublicKey, Peer, AgentRef, Goal, S));
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
    case {valid_public_key(PublicKey), valid_nonce(ClientNonce),
          network_and_node(S0)} of
        {false, _, _} ->
            {{error, invalid_public_key}, S0};
        {_, false, _} ->
            {{error, invalid_client_nonce}, S0};
        {_, _, {error, _} = Error} ->
            {Error, S0};
        {true, true, {ok, NetworkId, NodeKey}} ->
            %% A full challenge table is this node's availability condition,
            %% not a failed attempt by this caller. Check it before charging
            %% the caller's rate budget so a burst cannot lock out an agent.
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
    case verify_challenge(
           NetworkId, NodeKey, ChallengeId, PublicKey, ClientNonce,
           ServerNonce, {ExpiresMs, Signature}) of
        ok ->
            call({bind_session, PublicKey});
        {error, _} = Error -> Error
    end.

%% ======================================================================
%% sessions
%% ======================================================================

bind_session(<<_:256>> = PublicKey,
             S = #s{sessions = Sessions, session_ttl_ms = Ttl}) ->
    case sessions_full(S) of
        true ->
            {{error, client_session_busy}, S};
        false ->
            SessionId = crypto:strong_rand_bytes(32),
            ExpiresMs = quod_time:now_ms() + Ttl,
            %% A login proves possession of one key only. Agent identity is
            %% selected and signed in each goal request, never inferred here.
            Session = #{public_key => PublicKey,
                        expires_ms => ExpiresMs,
                        deadline => quod_time:mono_ms() + Ttl},
            {{ok, public_session(SessionId, Session)},
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

session_binding(SessionId, Session) ->
    public_session(SessionId, Session).

public_session(SessionId, #{public_key := PublicKey, expires_ms := ExpiresMs}) ->
    #{session_id => SessionId,
      expires_ms => ExpiresMs,
      public_key => PublicKey}.

sessions_full(#s{sessions = Sessions, max_sessions = Max}) ->
    map_size(Sessions) >= Max.

%% ======================================================================
%% plumbing
%% ======================================================================

charge(Field, Peer, Tag, S) ->
    case element(Field, S) of
        none ->
            {ok, S};
        Rate0 ->
            case quod_rate:allow(Peer, quod_time:mono_ms(), Rate0) of
                {ok, Rate} -> {ok, setelement(Field, S, Rate)};
                {busy, Rate} ->
                    {{error, tagged(Tag, busy)}, setelement(Field, S, Rate)};
                {rate_limited, Rate} ->
                    {{error, tagged(Tag, rate_limited)}, setelement(Field, S, Rate)}
            end
    end.

tagged(client_auth, busy) -> client_auth_busy;
tagged(client_auth, rate_limited) -> client_auth_rate_limited.

%% ======================================================================
%% signed goals
%% ======================================================================

admit_goal_request(SessionId, Peer, S0) ->
    case lookup_session(SessionId, S0) of
        {{ok, #{public_key := PublicKey} = Session}, S1} ->
            case charge_pair(
                   #s.goal_signing_key_rate, PublicKey,
                   #s.goal_peer_rate, Peer, S1) of
                {ok, S2} -> {{ok, Session}, S2};
                {{error, _} = Error, S2} -> {Error, S2}
            end;
        {{error, _} = Error, S1} ->
            {Error, S1}
    end.

admit_forwarded_goal_request(
  <<_:256>> = PublicKey, <<_:256>> = ForwarderKey, S0) ->
    case charge_pair(
           #s.goal_signing_key_rate, PublicKey,
           #s.goal_peer_rate, ForwarderKey, S0) of
        {ok, S1} -> {ok, S1};
        {{error, _} = Error, S1} -> {Error, S1}
    end;
admit_forwarded_goal_request(_PublicKey, _ForwarderKey, S) ->
    {{error, invalid_signing_key}, S}.

materialize_verified_goal(<<_:256>> = PublicKey, Peer, Goal, S0) ->
    case quod_wire_term:goal_symbol_names(Goal) of
        {ok, Names} ->
            NewNames = [Name || Name <- Names, not existing_atom(Name)],
            materialize_new_symbols(
              PublicKey, Peer, length(NewNames),
              fun() -> quod_wire_term:materialize_goal_symbols(Goal) end, S0);
        {error, _} ->
            {{error, invalid_goal}, S0}
    end;
materialize_verified_goal(_PublicKey, _Peer, _Goal, S) ->
    {{error, invalid_signing_key}, S}.

materialize_verified_request(
  <<_:256>> = PublicKey, Peer, AgentRef, Goal, S0) ->
    case {quod_wire_term:symbol_names(AgentRef),
          quod_wire_term:goal_symbol_names(Goal)} of
        {{ok, AgentNames}, {ok, GoalNames}} ->
            Names = ordsets:union(AgentNames, GoalNames),
            NewNames = [Name || Name <- Names, not existing_atom(Name)],
            materialize_new_symbols(
              PublicKey, Peer, length(NewNames),
              fun() -> materialize_request_terms(AgentRef, Goal) end, S0);
        _ ->
            {{error, invalid_goal}, S0}
    end;
materialize_verified_request(_PublicKey, _Peer, _AgentRef, _Goal, S) ->
    {{error, invalid_signing_key}, S}.

materialize_request_terms(AgentRef, Goal) ->
    case quod_wire_term:materialize_symbols(AgentRef) of
        {ok, MaterializedAgentRef} ->
            case quod_wire_term:materialize_goal_symbols(Goal) of
                {ok, MaterializedGoal} ->
                    {ok, {MaterializedAgentRef, MaterializedGoal}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

materialize_new_symbols(_PublicKey, _Peer, 0, Materialize, S) ->
    materialized_reply(Materialize(), S);
materialize_new_symbols(PublicKey, Peer, Count, Materialize,
                        #s{atom_baseline = Baseline,
                           max_materialized_atoms = Max} = S0)
  when Count > 0, is_function(Materialize, 0) ->
    Used = max(0, erlang:system_info(atom_count) - Baseline),
    case Used + Count =< Max of
        false ->
            {{error, client_symbol_budget_exhausted}, S0};
        true ->
            case charge_pair_many(
                   #s.symbol_signing_key_rate, PublicKey,
                   #s.symbol_peer_rate, Peer, Count, S0) of
                {{error, _} = Error, S1} ->
                    {Error, S1};
                {ok, S1} ->
                    %% The owner serializes client vocabulary allocation.  The
                    %% existing materializer still enforces per-request and VM
                    %% headroom limits shared with every other wire boundary.
                    materialized_reply(Materialize(), S1)
            end
    end.

materialized_reply({ok, Materialized}, S) -> {{ok, Materialized}, S};
materialized_reply({error, Reason}, S) -> {{error, Reason}, S}.

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
allow_many(_Key, _Remaining, _Now, none) ->
    {ok, none};
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

valid_public_key(<<_:256>>) -> true;
valid_public_key(_) -> false.

-doc "Canonical bytes for the unchanged short-lived proof-of-key challenge.".
-spec challenge_bytes(term(), term(), term(), term(), term(), term(), term()) ->
          {ok, binary()} | {error, invalid_challenge}.
challenge_bytes(<<_:256>> = NetworkId, <<_:256>> = NodeKey,
                <<_:128>> = ChallengeId, <<_:256>> = PublicKey,
                <<_:256>> = ClientNonce, <<_:256>> = ServerNonce,
                ExpiresMs)
  when is_integer(ExpiresMs), ExpiresMs > 0,
       ExpiresMs =< 16#FFFFFFFFFFFFFFFF ->
    {ok, <<?CHALLENGE_DOMAIN/binary, NetworkId/binary, NodeKey/binary,
           ChallengeId/binary, PublicKey/binary, ClientNonce/binary,
           ServerNonce/binary, ExpiresMs:64/unsigned-big>>};
challenge_bytes(_NetworkId, _NodeKey, _ChallengeId, _PublicKey,
                _ClientNonce, _ServerNonce, _ExpiresMs) ->
    {error, invalid_challenge}.

-doc "Verify an Ed25519 signature over one complete canonical challenge.".
-spec verify_challenge(term(), term(), term(), term(), term(), term(), term()) ->
          ok | {error, invalid_challenge | invalid_challenge_signature}.
verify_challenge(NetworkId, NodeKey, ChallengeId, PublicKey, ClientNonce,
                 ServerNonce, {ExpiresMs, Signature})
  when is_binary(Signature), byte_size(Signature) =:= 64 ->
    case challenge_bytes(NetworkId, NodeKey, ChallengeId, PublicKey,
                         ClientNonce, ServerNonce, ExpiresMs) of
        {ok, Bytes} ->
            case quod_identity:verify(Signature, Bytes, PublicKey) of
                true -> ok;
                false -> {error, invalid_challenge_signature}
            end;
        {error, _} = Error -> Error
    end;
verify_challenge(_NetworkId, _NodeKey, _ChallengeId, _PublicKey,
                 _ClientNonce, _ServerNonce, _Reply) ->
    {error, invalid_challenge}.
