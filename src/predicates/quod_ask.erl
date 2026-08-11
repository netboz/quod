-module(quod_ask).
-moduledoc """
The `::` selector — a goal in one ontology proved inside another
(`doc/inter-ontology.md`). Co-hosted and remote targets use the same reusable
proof-scope semantics; location changes only the scope transport.

- **Asking side** — `ask_2/3` is the erlog predicate registered on `{'::' ,2}`. It runs
  inside the asking proof's worker, enforces bounded depth and streams one solution per
  Prolog choice point. Recursive selection is ordinary Prolog recursion, including
  selecting an ontology already present in the semantic call chain.
- **Co-hosted target** — one origin proof owns one reusable target scope per pinned
  ontology. Repeated and re-entrant calls share its staged overlay while retaining
  independent bounded continuations.
- **Network target** — one authenticated, anchored scope session carries the
  same invocation, nested-call, and transaction-controller operations over QUIC.
  A raw snapshot proof has no transport fallback and cannot manufacture selector
  authority.

Errors are surfaced as `throw({quod_ask_error, Reason})`, which the proof runner
turns into the closed, typed catalog in `doc/distributed-proof-plan.md` §5.
Transport or protocol failure never masquerades as ordinary Prolog failure.
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_proof_limits.hrl").

-export([load/1, ask_2/3, follow_unique_2/3,
         authorize_scope/6, validate_authorization_transcript/6,
         close_stream/1]).
-ifdef(TEST).
-export([test_serve_nested/1, test_await_scope_reply/2,
         test_await_identity/4, test_await_remote_scope_open/4,
         test_remote_open_error/2, test_seed_confirmation_error/2,
         test_remember_route_error/2]).
-endif.

-doc "Register the `::` handler onto a freshly-built kb (`#est{}`).".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est) ->
    Db1 = erlog_int:add_compiled_proc({'::', 2}, ?MODULE, ask_2, Db0),
    Est#est{db = erlog_int:add_compiled_proc(
                   {'$quod_follow_unique', 1},
                   ?MODULE, follow_unique_2, Db1)}.

%%%===================================================================
%%% asking side — the erlog predicate + solution streaming
%%%===================================================================

%% Fires when a proof reaches `Ns::Goal` (parsed as `{'::' ,Ns,Goal}`). Runs in the
%% asking proof worker owned by `quod_prolog`.
ask_2(Goal, Next, #est{bs = Bs} = St) ->
    case erlog_int:dderef(Goal, Bs) of
        {'::', NsTerm, Inner} -> do_ask(NsTerm, Inner, Next, St);
        _                     -> erlog_int:fail(St)
    end.

%% The governing clause choice point owns this call's answer set. Erlog carries
%% that choice point while trying the remaining argument-position followers and
%% drops it on exhaustion or cut, so no state can survive into another invocation.
follow_unique_2(Goal, Next, #est{bs = Bs, cps = Cps} = St) ->
    {'$quod_follow_unique', Answer0} = erlog_int:dderef(Goal, Bs),
    Answer = erlog_int:dderef(Answer0, Bs),
    case remember_follow_answer(Answer, Bs, Cps) of
        duplicate ->
            erlog_int:fail(St);
        {new, Cps1} ->
            erlog_int:prove_body(Next, St#est{cps = Cps1});
        error ->
            ask_error({protocol_error, proof_engine})
    end.

remember_follow_answer(
  Answer, Bs,
  [#cp{type = goal_clauses, data = {Call, _Remaining},
       owned = Owned0} = Cp | Rest])
  when is_map(Owned0) ->
    case erlog_int:dderef(Call, Bs) =:= Answer of
        true ->
            Seen = maps:get({?MODULE, follower_answers}, Owned0, #{}),
            case maps:is_key(Answer, Seen) of
                true ->
                    duplicate;
                false ->
                    Owned1 = Owned0#{{?MODULE, follower_answers} =>
                                         Seen#{Answer => true}},
                    {new, [Cp#cp{owned = Owned1} | Rest]}
            end;
        false ->
            remember_follow_answer_above(Answer, Bs, Cp, Rest)
    end;
remember_follow_answer(Answer, Bs, [Cp | Rest]) ->
    remember_follow_answer_above(Answer, Bs, Cp, Rest);
remember_follow_answer(_Answer, _Bs, []) ->
    error.

remember_follow_answer_above(Answer, Bs, Cp, Rest) ->
    case remember_follow_answer(Answer, Bs, Rest) of
        {new, Rest1} -> {new, [Cp | Rest1]};
        Other -> Other
    end.

do_ask(NsTerm, Inner, Next, St) ->
    Self = quod_predicates:ctx_ns(quod_predicates:context(St)),
    case quod_ontology_name:flatten(NsTerm) of
        error  -> ask_error({bad_name, NsTerm});
        Self   -> erlog_int:prove_body([Inner | Next], St);  %% self-ask: in place, no hop, no chain growth
        Target -> guarded_ask(Self, Target, Inner, Next, St)
    end.

guarded_ask(Self, Target, Inner, Next, St) ->
    quod_predicates:local_only(St) andalso ask_error(ask_in_membership_verdict),
    Chain = quod_predicates:ctx_chain(quod_predicates:context(St)),
    length(Chain) >= ?QUOD_MAX_ACTIVE_PROOF_DEPTH andalso
        ask_error(
          {proof_depth_exceeded, ?QUOD_MAX_ACTIVE_PROOF_DEPTH}),
    InnerTerm = erlog_int:dderef(Inner, St#est.bs),
    case open(Self, Target, InnerTerm, Chain, St) of
        {ok, Stream, St1} ->
            drive_stream(Stream, InnerTerm, Target, Next, St1);
        {error, R}   -> ask_error(R)
    end.

%% Pull the next solution and either emit it (with a choice point for the one after) or,
%% when the target is exhausted, fail back into the surrounding proof.
drive_stream(Stream, GoalTerm, Target, Next, St) ->
    case stream_next(Stream, St) of
        {solution, Sol, Stream1, St1} ->
            emit(Stream1, GoalTerm, Target, Sol, Next, St1);
        {complete, Reasons, St1} ->
            case erlog_int:merge_failure_reasons(Reasons, St1) of
                {ok, St2} -> erlog_int:fail(St2);
                error -> ask_error({protocol_error, bad_payload})
            end;
        {error, R, _St1} -> ask_error(R)
    end.

%% Unify one target solution into the local proof. The pushed choice point captures the
%% PRE-unify bindings/var-counter, so backtracking restores them and pulls the next
%% solution — the streaming analogue of a clause choice point.
emit(Stream, GoalTerm, Target, Sol, Next, St = #est{bs = Bs, vn = Vn}) ->
    {Grafted, Vn1} = graft(Sol, Vn),   %% rename any target-side vars to fresh local ones
    case erlog_int:unify(GoalTerm, Grafted, Bs) of
        {succeed, Bs1} ->
            Fail = fun(#cp{bs = Bs0, vn = Vn0}, Cps, FSt) ->
                       drive_stream(Stream, GoalTerm, Target, Next,
                                    FSt#est{bs = Bs0, vn = Vn0, cps = Cps})
            end,
            Cp = #cp{type = compiled, data = Fail, next = Next, bs = Bs, vn = Vn},
            St1 = erlog_int:push_choicepoint(Cp, St),
            erlog_int:prove_body(Next, St1#est{bs = Bs1, vn = Vn1});
        fail ->
            %% This solution doesn't unify with the (partially bound) goal — skip it.
            drive_stream(Stream, GoalTerm, Target, Next, St)
    end.

%% Rename every variable (a 1-tuple in erlog) in a target solution term to a fresh local
%% var, consistently within the term, so target-side and asker-side var namespaces never
%% collide. Ground terms (the common case) pass through untouched.
graft(Term, Vn) -> {G, Vn1, _} = graft(Term, Vn, #{}), {G, Vn1}.

graft({Name}, Vn, Map) ->
    case Map of
        #{Name := V} -> {V, Vn, Map};
        _            -> {{Vn}, Vn + 1, Map#{Name => {Vn}}}
    end;
graft(T, Vn, Map) when is_tuple(T) ->
    {Args, Vn1, Map1} = graft_list(tuple_to_list(T), Vn, Map),
    {list_to_tuple(Args), Vn1, Map1};
graft([H | T], Vn, Map) ->
    {GH, Vn1, Map1} = graft(H, Vn, Map),
    {GT, Vn2, Map2} = graft(T, Vn1, Map1),
    {[GH | GT], Vn2, Map2};
graft(T, Vn, Map) -> {T, Vn, Map}.

graft_list([], Vn, Map)      -> {[], Vn, Map};
graft_list([H | T], Vn, Map) ->
    {GH, Vn1, Map1} = graft(H, Vn, Map),
    {GT, Vn2, Map2} = graft_list(T, Vn1, Map1),
    {[GH | GT], Vn2, Map2}.

-spec ask_error(term()) -> no_return().
ask_error(Reason) -> throw({quod_ask_error, Reason}).

%%%===================================================================
%%% ask selection — reusable co-hosted scopes and bounded transport invocations
%%%===================================================================

%% A shared proof session routes every selection through its one origin-owned
%% scope map. Raw snapshot adapters have no origin authority and are rejected
%% here before directory resolution, dialing, or target-worker allocation.
open(_Self, Target, GoalTerm, Chain, St) ->
    St1 = publish_session(St),
    case session_metadata(St1) of
        {origin, {quod_proof_context, _ProofId, Origin}} when Origin =:= self() ->
            %% Authority is established before activating distributed
            %% transaction state. A raw adapter therefore reaches the exact
            %% typed selector refusal below without creating controller state.
            ok = quod_transaction_scope:activate(St1),
            Actor = quod_transaction_scope:current_actor(),
            Selection = quod_transaction_scope:current_selection(St1),
            case origin_open(Target, GoalTerm, Chain, Actor, Selection) of
                {ok, Stream} -> {ok, Stream, refresh_session(St1)};
                {error, _} = Error -> Error
            end;
        {scope, ProofId, Origin, _SessionRef, ScopeId}
          when is_pid(Origin), is_binary(ScopeId), byte_size(ScopeId) =:= 16 ->
            ok = quod_transaction_scope:activate(St1),
            Actor = quod_transaction_scope:current_actor(),
            Selection = quod_transaction_scope:current_selection(St1),
            case Actor of
                {ScopeId, _InvocationId} ->
                    case nested_open(
                           Origin, ProofId, Target, GoalTerm, Chain,
                           Actor, Selection) of
                        {ok, Stream} -> {ok, Stream, refresh_session(St1)};
                        {error, _} = Error -> Error
                    end;
                _ ->
                    {error, {protocol_error, session_binding}}
            end;
        _ ->
            {error, {ask_requires_anchored_proof, Target}}
    end.

origin_open(Target, Goal, Chain, OwnerActor, Selection) ->
    case origin_scope(Target) of
        {ok, _ScopeId, Scope} ->
            case open_scope_invocation(Scope, Goal, Chain, Selection) of
                {ok, Invocation} ->
                    case quod_proof_context:new_proxy(
                           OwnerActor, Target, Invocation) of
                        {ok, Ref} -> {ok, {origin_scope_stream, Ref, 1}};
                        {error, _} = Error ->
                            close_stream(Invocation),
                            Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

origin_scope(Target) ->
    case quod_reg:where({quod_prolog, Target}) of
        undefined -> open_directory_scope(Target);
        _Engine ->
            case quod_simplex:genesis_hash(Target) of
                <<_:256>> = Anchor ->
                    Identity = {Target, Anchor},
                    quod_proof_context:get_or_open_scope(
                      Identity,
                      fun(ScopeId) ->
                          open_cohosted_scope(Target, Anchor, ScopeId)
                      end);
                undefined ->
                    {error, {ontology_unreachable, Target}}
            end
    end.

open_cohosted_scope(Target, Anchor, ScopeId) ->
    case quod_reg:where({quod_prolog, Target}) of
        undefined -> {error, {ontology_unreachable, Target}};
        Engine ->
            case execution_remaining_ms() of
                0 -> {error, current_proof_limit()};
                RemainingMs ->
                    ProofId = quod_proof_context:proof_id(),
                    ReadOnly = quod_proof_context:read_only(),
                    try gen_server:call(
                          Engine,
                          {scope_open, ScopeId, ProofId, Anchor, ReadOnly,
                           quod_proof_context:deadline_ms()},
                          RemainingMs) of
                        {ok, Handle} ->
                            {ok, quod_scope_session:pid(Handle), Handle};
                        {error, TargetReason} -> {error, TargetReason}
                    catch exit:_ ->
                        {error, {ontology_unreachable, Target}}
                    end
            end
    end.

open_directory_scope(Target) ->
    case quod_directory:resolve(Target) of
        unknown -> {error, {unknown_ontology, Target}};
        {known, []} -> {error, {ontology_unreachable, Target}};
        {known, Routes} -> choose_directory_scope(Target, Routes)
    end.

choose_directory_scope(Target, Routes) ->
    Confirmed = [Route || Route = #{scope := direct, status := confirmed}
                              <- Routes],
    Provisional = [Route || Route = #{scope := direct, status := provisional}
                                <- Routes],
    System = [Route || Route = #{scope := system} <- Routes],
    case Confirmed of
        [_ | _] -> open_anchored_routes(Target, Confirmed);
        [] -> probe_direct_routes(Target, Provisional, System, none)
    end.

probe_direct_routes(Target, [], System, BestError) ->
    case open_anchored_routes(Target, System) of
        {error, {ontology_unreachable, Target}} when BestError =/= none ->
            {error, BestError};
        Result -> Result
    end;
probe_direct_routes(Target,
                    [#{endpoint := Endpoint} = Route | Rest], System,
                    BestError) ->
    case identify_direct_seed(Target, Endpoint) of
        {ok, NodeKey, {Target, Anchor}, Role} ->
            case quod_directory:confirm_direct_seed(
                   Target, Endpoint, NodeKey, Anchor, Role) of
                ok ->
                    Confirmed = Route#{status => confirmed,
                                       node_key => NodeKey,
                                       genesis_anchor => Anchor,
                                       role => Role},
                    open_anchored_routes(Target, [Confirmed]);
                {error, Reason} ->
                    continue_seed_routes(
                      Target, Rest, System, BestError,
                      seed_confirmation_error(Target, Reason))
            end;
        {ok, _NodeKey, _WrongIdentity, _Role} ->
            {error, {protocol_error, identity_binding}};
        {error, Reason} ->
            continue_seed_routes(
              Target, Rest, System, BestError,
              remote_open_error(Target, Reason))
    end.

continue_seed_routes(Target, Rest, System, BestError, unavailable) ->
    probe_direct_routes(Target, Rest, System, BestError);
continue_seed_routes(Target, Rest, System, BestError,
                     {retry, PublicReason}) ->
    probe_direct_routes(
      Target, Rest, System,
      remember_route_error(BestError, PublicReason));
continue_seed_routes(_Target, _Rest, _System, _BestError,
                     {fatal, PublicReason}) ->
    {error, PublicReason}.

seed_confirmation_error(_Target, unknown_seed) ->
    unavailable;
seed_confirmation_error(_Target, Reason)
  when Reason =:= seed_identity_conflict;
       Reason =:= ambiguous_seed;
       Reason =:= bad_seed_identity ->
    {fatal, {protocol_error, identity_binding}};
seed_confirmation_error(_Target, _Reason) ->
    {fatal, {protocol_error, proof_engine}}.

identify_direct_seed(Target, Endpoint) ->
    case execution_remaining_ms() of
        0 -> {error, current_proof_limit()};
        RemainingMs ->
            case quod_ask_router:identify(Endpoint, Target, RemainingMs) of
                {pending, Router, Generation, OpenRef} ->
                    await_identity(Target, Router, Generation, OpenRef);
                {error, _} = Error -> Error
            end
    end.

await_identity(Target, Router, Generation, OpenRef) ->
    case quod_proof_context:bind_router(Router, Generation, Target) of
        {ok, MRef} ->
            receive
                {quod_scope_identity, OpenRef, Result} -> Result;
                {'DOWN', MRef, process, Router, _Reason} ->
                    {error, {ontology_unreachable, Target}}
            end;
        {error, _} = Error ->
            Error
    end.

open_anchored_routes(Target, Routes) ->
    Eligible = eligible_routes(Routes),
    Anchors = lists:usort(
                [Anchor || #{genesis_anchor := Anchor} <- Eligible,
                           is_binary(Anchor), byte_size(Anchor) =:= 32]),
    case {Eligible, Anchors} of
        {[], _} -> {error, {ontology_unreachable, Target}};
        {_, [Anchor]} ->
            Identity = {Target, Anchor},
            quod_proof_context:get_or_open_scope(
              Identity,
              fun(ScopeId) ->
                  open_remote_routes(Target, Anchor, ScopeId, Eligible)
              end);
        _ -> {error, {anchor_conflict, Target}}
    end.

eligible_routes(Routes) ->
    ReadOnly = quod_proof_context:read_only(),
    [Route || Route = #{role := Role} <- Routes,
              Role =:= validator orelse
                  (ReadOnly andalso Role =:= observer)].

open_remote_routes(Target, Anchor, ScopeId, Routes) ->
    open_remote_routes(Target, Anchor, ScopeId, Routes, none).

open_remote_routes(Target, _Anchor, _ScopeId, [], none) ->
    {error, {ontology_unreachable, Target}};
open_remote_routes(_Target, _Anchor, _ScopeId, [], BestError) ->
    {error, BestError};
open_remote_routes(Target, Anchor, ScopeId,
                   [#{node_key := TargetKey, endpoint := Endpoint} | Rest],
                   BestError) ->
    OriginKey = required_node_key(),
    Mode = case quod_proof_context:read_only() of
               true -> read_only;
               false -> read_write
           end,
    Binding = {scope_binding, OriginKey, TargetKey,
               quod_proof_context:proof_id(), ScopeId,
               quod_proof_context:origin_identity(), {Target, Anchor}, Mode},
    case ensure_remote_scope(Endpoint, Binding) of
        {ok, Handle} ->
            {ok, quod_scope_session:pid(Handle), Handle};
        {error, Reason} ->
            case remote_open_error(Target, Reason) of
                unavailable ->
                    open_remote_routes(
                      Target, Anchor, ScopeId, Rest, BestError);
                {retry, PublicReason} ->
                    open_remote_routes(
                      Target, Anchor, ScopeId, Rest,
                      remember_route_error(BestError, PublicReason));
                {fatal, PublicReason} ->
                    {error, PublicReason}
            end
    end;
open_remote_routes(Target, Anchor, ScopeId, [_Invalid | Rest], BestError) ->
    open_remote_routes(Target, Anchor, ScopeId, Rest, BestError).

ensure_remote_scope(Endpoint, Binding) ->
    Target = binding_target_namespace(Binding),
    case execution_remaining_ms() of
        0 -> {error, current_proof_limit()};
        RemainingMs ->
            case quod_ask_router:ensure_scope(
                   Endpoint, Binding, RemainingMs) of
                {ok, Handle} -> bind_open_handle(Target, Handle);
                {pending, Router, Generation, OpenRef} ->
                    await_remote_scope_open(
                      Target, Router, Generation, OpenRef);
                {error, _} = Error -> Error
            end
    end.

bind_open_handle(
  Target,
  {remote_scope, Router, Generation, _Binding, _RequestLink} = Handle) ->
    case quod_proof_context:bind_router(Router, Generation, Target) of
        {ok, _MRef} -> {ok, Handle};
        {error, _} = Error -> Error
    end;
bind_open_handle(_Target, _Handle) ->
    {error, {protocol_error, session_binding}}.

await_remote_scope_open(Target, Router, Generation, OpenRef) ->
    case quod_proof_context:bind_router(Router, Generation, Target) of
        {ok, MRef} ->
            receive
                {quod_scope_open, OpenRef,
                 {ok, Handle, _BaseHeight, _OverlayGeneration, false}} ->
                    bind_open_handle(Target, Handle);
                {quod_scope_open, OpenRef, {ok, _Handle, _BaseHeight,
                                            _OverlayGeneration, true}} ->
                    {error, {protocol_error, bad_dirty}};
                {quod_scope_open, OpenRef, {error, Reason}} ->
                    {error, Reason};
                {'DOWN', MRef, process, Router, _Reason} ->
                    {error, {ontology_unreachable, Target}}
            end;
        {error, _} = Error ->
            Error
    end.

binding_target_namespace(
  {scope_binding, _, _, _, _, _, {Target, _Anchor}, _Mode}) -> Target.

remember_route_error(none, Reason) -> Reason;
remember_route_error(Reason, _LaterReason) -> Reason.

remote_open_error(Target, Reason) ->
    case router_admission_error(Target, Reason) of
        unclassified -> target_open_error(Target, Reason);
        Classification -> Classification
    end.

router_admission_error(_Target, Reason)
  when Reason =:= unavailable; Reason =:= timeout;
       Reason =:= invalid_endpoint; Reason =:= link_binding_mismatch ->
    unavailable;
router_admission_error(_Target, {request_link_down, _Reason}) -> unavailable;
router_admission_error(_Target, {return_link_down, _Reason}) -> unavailable;
router_admission_error(_Target, {scope_limit_exceeded, _Max} = Reason) ->
    %% This is a per-peer target admission bound. Another eligible host can
    %% still admit the same immutable scope request before any execution.
    {retry, Reason};
router_admission_error(_Target, peer_scope_limit) ->
    {retry,
     {scope_limit_exceeded, ?QUOD_MAX_ROUTER_SCOPES_PER_PEER}};
router_admission_error(_Target, owner_scope_limit) ->
    {fatal,
     {scope_limit_exceeded, ?QUOD_MAX_ROUTER_SCOPES_PER_OWNER}};
router_admission_error(_Target, router_full) ->
    {fatal, {scope_limit_exceeded, ?QUOD_MAX_ROUTER_SCOPES}};
router_admission_error(Target, {proof_poisoned, Reason}) ->
    {fatal, normalize_router_failure(Target, Reason)};
router_admission_error(_Target, {protocol_error, _} = Reason) ->
    case quod_scope_wire:valid_public_error(Reason) of
        true -> {fatal, Reason};
        false -> {fatal, {protocol_error, proof_engine}}
    end;
router_admission_error(_Target, {proof_limit_exceeded, _} = Reason) ->
    {fatal, Reason};
router_admission_error(_Target, {too_large, scope_envelope} = Reason) ->
    {fatal, Reason};
router_admission_error(_Target, Reason)
  when Reason =:= invalid_binding; Reason =:= scope_binding_conflict;
       Reason =:= owner_proof_conflict; Reason =:= proof_finalized ->
    {fatal, {protocol_error, session_binding}};
router_admission_error(_Target, _Reason) ->
    unclassified.

target_open_error(Target, {not_allowed, Target} = Reason) -> {retry, Reason};
target_open_error(Target, {ontology_busy, Target} = Reason) -> {retry, Reason};
target_open_error(Target, {ontology_rate_limited, Target} = Reason) ->
    {retry, Reason};
target_open_error(Target, {ontology_rebuilding, Target} = Reason) ->
    {retry, Reason};
target_open_error(Target, {anchor_conflict, Target} = Reason) ->
    {fatal, Reason};
target_open_error(Target, {ontology_unreachable, Target} = Reason) ->
    {fatal, Reason};
target_open_error(Target, {unknown_ontology, Target} = Reason) ->
    {fatal, Reason};
target_open_error(Target, {scope_expired, Target} = Reason) ->
    {fatal, Reason};
target_open_error(_Target, Reason) ->
    {fatal, {protocol_error, remote_open_error_kind(Reason)}}.

normalize_router_failure(Target, {scope_error, Reason}) ->
    quod_scope_wire:normalize_public_error(Reason, Target);
normalize_router_failure(Target, {request_link_down, _Reason}) ->
    {ontology_unreachable, Target};
normalize_router_failure(Target, {return_link_down, _Reason}) ->
    {ontology_unreachable, Target};
normalize_router_failure(Target, {protocol_error, _} = Reason) ->
    quod_scope_wire:normalize_public_error(Reason, Target);
normalize_router_failure(Target, _Reason) ->
    {ontology_unreachable, Target}.

remote_open_error_kind(invalid_binding) -> session_binding;
remote_open_error_kind(scope_binding_conflict) -> session_binding;
remote_open_error_kind(owner_proof_conflict) -> session_binding;
remote_open_error_kind(proof_finalized) -> session_binding;
remote_open_error_kind(_Reason) -> proof_engine.

-ifdef(TEST).
test_remote_open_error(Target, Reason) -> remote_open_error(Target, Reason).
test_seed_confirmation_error(Target, Reason) ->
    seed_confirmation_error(Target, Reason).
test_remember_route_error(Current, Reason) ->
    remember_route_error(Current, Reason).
test_await_identity(Target, Router, Generation, OpenRef) ->
    await_identity(Target, Router, Generation, OpenRef).
test_await_remote_scope_open(Target, Router, Generation, OpenRef) ->
    await_remote_scope_open(Target, Router, Generation, OpenRef).
-endif.

current_proof_limit() ->
    {OriginNs, _Anchor} = quod_proof_context:origin_identity(),
    {proof_limit_exceeded, OriginNs}.

-doc "The engine-owned node principal every authorization decision binds to.".
-spec required_node_key() -> <<_:256>>.
required_node_key() ->
    case application:get_env(quod, node_pubkey) of
        {ok, <<_:256>> = NodeKey} -> NodeKey;
        _ -> erlang:error(node_pubkey_required)
    end.

execution_remaining_ms() ->
    case quod_scope_session:remaining_ms() of
        {ok, RemainingMs} -> RemainingMs;
        error -> quod_proof_context:remaining_ms()
    end.

open_scope_invocation(
  {local_scope, ScopeId, Ns, Anchor, Height, Session},
  Goal, Chain, Selection) ->
    %% Record the requested goal and authorization verdict separately. The
    %% session substitutes the bounded failure goal only for execution, so a
    %% validator can later re-check the exact request that policy denied.
    Verdict =
        case authorize_scope(quod_proof_context:principal(), Goal, Chain,
                             {Ns, Anchor}, Height, Session) of
            true  -> allowed;
            false -> denied
        end,
    InvocationId = crypto:strong_rand_bytes(16),
    Context = quod_predicates:proof_context(
                Ns, Height, undefined, [{Ns, Anchor} | Chain]),
    case quod_proof_session:open(
           Session, InvocationId, Goal, Verdict, Context, Selection) of
        ok -> finish_scope_open(
                {local_scope_invocation, ScopeId, Session,
                 InvocationId, Selection, 1});
        {error, TargetReason} -> {error, TargetReason}
    end;
open_scope_invocation(Handle, Goal, Chain, Selection) ->
    InvocationId = crypto:strong_rand_bytes(16),
    case quod_scope_session:invoke_open(
           Handle, InvocationId, Goal, Chain, Selection) of
        {ok, Correlation} ->
            case await_scope_reply(
                   Handle, Correlation, {open, InvocationId}) of
                {opened, InvocationId} ->
                    finish_scope_open(
                      {scope_invocation, Handle,
                       InvocationId, Selection, 1});
                {error, Reason} ->
                    _ = quod_scope_session:invoke_cancel(
                          Handle, InvocationId),
                    {error, Reason};
                _ ->
                    _ = quod_scope_session:invoke_cancel(
                          Handle, InvocationId),
                    {error, {protocol_error, request_binding}}
            end;
        {error, _} = Error ->
            Error
    end.

finish_scope_open(Invocation) ->
    Actor = invocation_actor(Invocation),
    Selection = invocation_selection(Invocation),
    case quod_proof_context:register_invocation(Actor, Selection) of
        ok ->
            case quod_proof_context:materialize(Selection, Actor) of
                ok -> {ok, Invocation};
                {error, _} = Error ->
                    _ = cancel_scope_invocation(Invocation),
                    quod_proof_context:unregister_invocation(Actor),
                    Error
            end;
        {error, _} = Error ->
            _ = cancel_scope_invocation(Invocation),
            Error
    end.

invocation_actor(
  {scope_invocation, Handle, InvocationId, _Selection, _Expected}) ->
    {quod_scope_session:scope_id(Handle), InvocationId};
invocation_actor(
  {local_scope_invocation, ScopeId, _Session,
   InvocationId, _Selection, _Expected}) ->
    {ScopeId, InvocationId}.

invocation_selection(
  {scope_invocation, _Handle, _InvocationId, Selection, _Expected}) ->
    Selection;
invocation_selection(
  {local_scope_invocation, _ScopeId, _Session,
   _InvocationId, Selection, _Expected}) ->
    Selection.

cancel_scope_invocation(
  {scope_invocation, Handle, InvocationId, _Selection, _Expected}) ->
    quod_scope_session:invoke_cancel(Handle, InvocationId);
cancel_scope_invocation(
  {local_scope_invocation, _ScopeId, Session,
   InvocationId, _Selection, _Expected}) ->
    quod_proof_session:cancel(Session, InvocationId).

stream_next(Stream, St) ->
    St1 = publish_session(St),
    Actor = quod_transaction_scope:current_actor(),
    Selection = quod_transaction_scope:current_selection(St1),
    Result =
        case Stream of
            {origin_scope_stream, Ref, Expected} ->
                origin_advance(Ref, Actor, Selection, Expected);
            {nested_scope_stream, Origin, ProofId, Ref,
             Actor, _StreamSelection, Expected} ->
                nested_advance(
                  Origin, ProofId, Ref, Actor, Selection, Expected);
            _ ->
                {error, {protocol_error, session_binding}}
        end,
    St2 = refresh_session(St1),
    case Result of
        {solution, Solution, NextStream} ->
            {solution, Solution, NextStream, St2};
        {complete, Reasons} ->
            {complete, Reasons, St2};
        {error, Reason} ->
            {error, Reason, St2}
    end.

origin_advance(Ref, OwnerActor, OwnerSelection, Expected) ->
    Result = case quod_proof_context:proxy(Ref, OwnerActor) of
        {ok, {scope_invocation, Handle, InvocationId,
              TargetSelection, Expected}} ->
            TargetActor = {quod_scope_session:scope_id(Handle), InvocationId},
            case quod_proof_context:materialize(
                   TargetSelection, TargetActor) of
                ok ->
                    case quod_scope_session:invoke_next(
                           Handle, InvocationId, Expected) of
                        {ok, Correlation} ->
                            scope_advance_reply(
                              Ref, OwnerActor, Handle, InvocationId,
                              TargetSelection, Expected,
                              await_scope_reply(
                                Handle, Correlation,
                                {TargetActor, TargetSelection, Expected}));
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {ok, {local_scope_invocation, ScopeId, Session, InvocationId,
              TargetSelection, Expected}} ->
            TargetActor = {ScopeId, InvocationId},
            case quod_proof_context:materialize(
                   TargetSelection, TargetActor) of
                ok ->
                    local_advance_reply(
                      Ref, OwnerActor, ScopeId, Session, InvocationId,
                      TargetSelection, Expected,
                      quod_proof_session:next(Session, InvocationId));
                {error, Reason} -> {error, Reason}
            end;
        {ok, _WrongSequence} ->
            {error, {protocol_error, answer_sequence}};
        {error, _} ->
            {error, {protocol_error, request_binding}}
    end,
    case quod_proof_context:materialize(OwnerSelection, OwnerActor) of
        ok -> Result;
        {error, ResumeReason} -> {error, ResumeReason}
    end.

scope_advance_reply(Ref, Owner, Handle, InvocationId, Selection, Expected,
                    {solution, Expected, Solution, Dirty}) ->
    ScopeId = quod_scope_session:scope_id(Handle),
    ok = quod_proof_context:mark_dirty(ScopeId, Dirty),
    Next = {scope_invocation, Handle, InvocationId,
            Selection, Expected + 1},
    ok = quod_proof_context:update_proxy(Ref, Owner, Next),
    {solution, Solution, origin_stream(Ref, Expected + 1)};
scope_advance_reply(Ref, Owner, Handle, InvocationId, _Selection, Expected,
                    {complete, Expected, Reasons, Dirty}) ->
    ok = quod_proof_context:mark_dirty(
           quod_scope_session:scope_id(Handle), Dirty),
    finish_proxy_invocation(Ref, Owner,
                            {quod_scope_session:scope_id(Handle), InvocationId}),
    {complete, Reasons};
scope_advance_reply(Ref, Owner, Handle, InvocationId, _Selection, _Expected,
                    {error, Reason, Dirty}) ->
    %% The error aborts this proof, but retaining the final dirty bit keeps the
    %% origin's scope accounting exact while cleanup runs.
    ok = quod_proof_context:mark_dirty(
           quod_scope_session:scope_id(Handle), Dirty),
    finish_proxy_invocation(Ref, Owner,
                            {quod_scope_session:scope_id(Handle), InvocationId}),
    {error, Reason};
scope_advance_reply(Ref, Owner, Handle, InvocationId, _Selection, _Expected,
                    {error, Reason}) ->
    _ = quod_scope_session:invoke_cancel(Handle, InvocationId),
    finish_proxy_invocation(Ref, Owner,
                            {quod_scope_session:scope_id(Handle), InvocationId}),
    {error, Reason};
scope_advance_reply(Ref, Owner, Handle, InvocationId, _Selection,
                    _Expected, _Reply) ->
    _ = quod_scope_session:invoke_cancel(Handle, InvocationId),
    finish_proxy_invocation(Ref, Owner,
                            {quod_scope_session:scope_id(Handle), InvocationId}),
    {error, {protocol_error, request_binding}}.

local_advance_reply(Ref, Owner, ScopeId, Session, InvocationId,
                    Selection, Expected,
                    {solution, Solution}) ->
    Next = {local_scope_invocation, ScopeId, Session, InvocationId,
            Selection, Expected + 1},
    ok = quod_proof_context:update_proxy(Ref, Owner, Next),
    {solution, Solution, origin_stream(Ref, Expected + 1)};
local_advance_reply(Ref, Owner, ScopeId, _Session, InvocationId,
                    _Selection, _Expected,
                    {complete, Reasons}) ->
    finish_proxy_invocation(Ref, Owner, {ScopeId, InvocationId}),
    {complete, Reasons};
local_advance_reply(Ref, Owner, ScopeId, _Session, InvocationId,
                    _Selection, _Expected,
                    {error, Reason}) ->
    finish_proxy_invocation(Ref, Owner, {ScopeId, InvocationId}),
    {error, Reason}.

finish_proxy_invocation(Ref, Owner, Actor) ->
    quod_proof_context:unregister_invocation(Actor),
    _ = quod_proof_context:drop_proxy(Ref, Owner),
    ok.

origin_stream(Ref, Expected) -> {origin_scope_stream, Ref, Expected}.

nested_open(Origin, ProofId, Target, Goal, Chain, Actor, Selection) ->
    RequestRef = make_ref(),
    Origin ! {proof_nested_open, ProofId, self(), RequestRef,
              Actor, Selection, Target, Goal, Chain},
    case await_nested_reply(Origin, ProofId, RequestRef) of
        {opened, Ref} ->
            {ok, {nested_scope_stream, Origin, ProofId, Ref,
                  Actor, Selection, 1}};
        {error, Reason} ->
            {error, Reason};
        _ ->
            {error, {protocol_error, request_binding}}
    end.

nested_advance(Origin, ProofId, Ref, Actor, Selection, Expected) ->
    RequestRef = make_ref(),
    Origin ! {proof_nested_next, ProofId, self(), RequestRef,
              Actor, Selection, Ref, Expected},
    case await_nested_reply(Origin, ProofId, RequestRef) of
        {solution, Expected, Solution} ->
            {solution, Solution,
             {nested_scope_stream, Origin, ProofId, Ref,
              Actor, Selection, Expected + 1}};
        {complete, Expected, Reasons} ->
            {complete, Reasons};
        {error, Reason} ->
            request_nested_cancel(
              Origin, ProofId, Actor, Selection, Ref),
            {error, Reason};
        _ ->
            request_nested_cancel(
              Origin, ProofId, Actor, Selection, Ref),
            {error, {protocol_error, request_binding}}
    end.

await_nested_reply(Origin, ProofId, RequestRef) ->
    receive
        {proof_nested_reply, ProofId, RequestRef, Reply} ->
            Reply;
        Message = {scope_invoke_open, _, _, _, _, _, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef);
        Message = {scope_invoke_next, _, _, _, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef);
        Message = {scope_invoke_cancel, _, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef);
        Message = {scope_savepoint, _, _, _, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef);
        Message = {scope_seal, _, _, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef);
        Message = {scope_close, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef)
    end.

dispatch_reentrant(Message, Origin, ProofId, RequestRef) ->
    case quod_scope_session:dispatch(Message) of
        stop -> exit(normal);
        _ -> await_nested_reply(Origin, ProofId, RequestRef)
    end.

await_scope_reply(
  {remote_scope, Router, Generation, _Binding, _RequestLink} = Handle,
  RequestRef, ControllerContext) ->
    {Target, _Anchor} = quod_scope_session:identity(Handle),
    case quod_proof_context:bind_router(Router, Generation, Target) of
        {ok, MRef} ->
            await_scope_reply_loop(
              Handle, RequestRef, ControllerContext, MRef);
        {error, Reason} ->
            {error, Reason}
    end;
await_scope_reply(Handle, RequestRef, ControllerContext) ->
    Pid = quod_scope_session:pid(Handle),
    MRef = monitor(process, Pid),
    try await_scope_reply_loop(
          Handle, RequestRef, ControllerContext, MRef)
    after demonitor(MRef, [flush])
    end.

await_scope_reply_loop(
  {quod_scope_session, Pid, _ScopeId, ProofId, SessionRef,
   _Ns, _Anchor} = Handle,
  RequestRef, ControllerContext, MRef) ->
    receive
        {scope_reply, Pid, ProofId, SessionRef, RequestRef, Reply} ->
            Reply;
        Message = {proof_nested_open, _, _, _, _, _, _, _, _} ->
            serve_nested(Message),
            await_scope_reply_loop(
              Handle, RequestRef, ControllerContext, MRef);
        Message = {proof_nested_next, _, _, _, _, _, _, _} ->
            serve_nested(Message),
            await_scope_reply_loop(
              Handle, RequestRef, ControllerContext, MRef);
        Message = {proof_nested_cancel, _, _, _, _, _} ->
            serve_nested(Message),
            await_scope_reply_loop(
              Handle, RequestRef, ControllerContext, MRef);
        Message = {proof_tx_request, _, _, _, _, _, _} ->
            serve_tx_request(Message),
            await_scope_reply_loop(
              Handle, RequestRef, ControllerContext, MRef);
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, quod_scope_session:failure_reason(Handle, Reason)}
    end;
await_scope_reply_loop(
  {remote_scope, Router, _RouterGeneration, _Binding, _RequestLink} = Handle,
  RequestId, ControllerContext, MRef) ->
    receive
        {quod_scope_event, Handle, RequestId, _Generation, Dirty, Operation} ->
            case quod_proof_context:mark_dirty(
                   quod_scope_session:scope_id(Handle), Dirty) of
                ok ->
                    case decode_remote_scope_event(
                           Handle, Operation, Dirty, ControllerContext) of
                        continue ->
                            await_scope_reply_loop(
                              Handle, RequestId, ControllerContext, MRef);
                        Reply -> Reply
                    end;
                {error, _} -> {error, {protocol_error, session_binding}}
            end;
        {quod_scope_down, Handle, Reason} ->
            {error, quod_scope_session:failure_reason(Handle, Reason)};
        {'DOWN', MRef, process, Router, _Reason} ->
            {error, quod_scope_session:failure_reason(Handle, unavailable)}
    end.

decode_remote_scope_event(_Handle, {invocation_opened, InvocationId},
                          _Dirty, {open, InvocationId}) ->
    {opened, InvocationId};
decode_remote_scope_event(_Handle,
                          {invocation_error, InvocationId, 1, Reason},
                          false, {open, InvocationId}) ->
    {error, Reason};
decode_remote_scope_event(_Handle,
                          {solution, InvocationId, AnswerSeq, Blob},
                          Dirty,
                          {{_ScopeId, InvocationId}, _Selection, AnswerSeq}) ->
    decoded_scope_payload(
      answer, Blob,
      fun(Solution) -> {solution, AnswerSeq, Solution, Dirty} end);
decode_remote_scope_event(_Handle,
                          {complete, InvocationId, AnswerSeq, Blob},
                          Dirty,
                          {{_ScopeId, InvocationId}, _Selection, AnswerSeq}) ->
    decoded_scope_payload(
      failure_reasons, Blob,
      fun(Reasons) ->
          case checked_completion(Reasons) of
              {complete, Checked} ->
                  {complete, AnswerSeq, Checked, Dirty};
              error -> {error, {protocol_error, bad_payload}}
          end
      end);
decode_remote_scope_event(_Handle,
                          {erlog_error, InvocationId, AnswerSeq, Blob},
                          Dirty,
                          {{_ScopeId, InvocationId}, _Selection, AnswerSeq}) ->
    decoded_scope_payload(
      erlog_error, Blob,
      fun(Error) -> {error, {erlog, Error}, Dirty} end);
decode_remote_scope_event(_Handle,
                          {invocation_error, InvocationId, AnswerSeq, Reason},
                          Dirty,
                          {{_ScopeId, InvocationId}, _Selection, AnswerSeq}) ->
    {error, Reason, Dirty};
decode_remote_scope_event(_Handle, {scope_error, Reason},
                          Dirty, _ControllerContext) ->
    {error, Reason, Dirty};
decode_remote_scope_event(Handle, Operation, _Dirty,
                          {Actor, Selection, _Expected}) ->
    case serve_remote_controller(Handle, Operation, Actor, Selection) of
        ok -> continue;
        {error, Reason} -> {error, Reason}
    end;
decode_remote_scope_event(_Handle, _Operation, _Dirty, _Context) ->
    {error, {protocol_error, request_binding}}.

decoded_scope_payload(Kind, Blob, BuildReply) ->
    case quod_scope_wire:decode_payload(Kind, Blob) of
        {ok, Term} -> BuildReply(Term);
        {error, Reason} -> {error, Reason}
    end.

serve_remote_controller(Handle,
                        {nested_open, ControllerId, Target, Chain, GoalBlob},
                        Actor, Selection) ->
    case remote_controller_source(Handle, Actor, Selection) of
        false -> {error, not_allowed};
        true ->
            case quod_scope_wire:decode_payload(goal, GoalBlob) of
                {ok, Goal} ->
                    Reply = case origin_open(
                                   Target, Goal, Chain, Actor, Selection) of
                                {ok, {origin_scope_stream, ProxyId, 1}} ->
                                    {nested_opened, ControllerId, ProxyId};
                                {error, Reason} ->
                                    {nested_error, ControllerId,
                                     public_controller_error(Reason)}
                            end,
                    send_controller_reply(Handle, Reply);
                {error, Reason} -> {error, Reason}
            end
    end;
serve_remote_controller(Handle,
                        {nested_next, ControllerId, ProxyId, Expected},
                        Actor, Selection) ->
    case remote_controller_source(Handle, Actor, Selection) of
        false -> {error, not_allowed};
        true ->
            send_nested_advance_reply(
              Handle, ControllerId, ProxyId, Expected,
              origin_advance(ProxyId, Actor, Selection, Expected))
    end;
serve_remote_controller(Handle,
                        {nested_cancel, _ControllerId, ProxyId},
                        Actor, Selection) ->
    case remote_controller_source(Handle, Actor, Selection) of
        false -> {error, not_allowed};
        true ->
            case cancel_origin_proxy(ProxyId, Actor) of
                ok -> ok;
                {error, _} -> ok
            end
    end;
serve_remote_controller(Handle,
                        {tx_activate, ControllerId, InvocationId,
                         ParentLineage, FrameIds},
                        {ScopeId, InvocationId} = Actor, Selection) ->
    controller_request(
      Handle, ControllerId, Actor, Selection,
      fun() -> quod_proof_context:tx_request(
                 Actor, {activate, ParentLineage, FrameIds}) end,
      fun({ok, FinalLineage, Activated}) ->
              {tx_activated, ControllerId, FinalLineage, Activated}
      end,
      ScopeId);
serve_remote_controller(Handle,
                        {tx_finish, ControllerId, InvocationId,
                         Lineage, TxId, Mode},
                        {ScopeId, InvocationId} = Actor, Selection)
  when Mode =:= finish; Mode =:= discard ->
    controller_request(
      Handle, ControllerId, Actor, Selection,
      fun() -> quod_proof_context:tx_request(
                 Actor, {Mode, Lineage, TxId}) end,
      fun({ok, ParentLineage}) ->
              {tx_finished, ControllerId, ParentLineage}
      end,
      ScopeId);
serve_remote_controller(Handle,
                        {savepoint_allocate, ControllerId, InvocationId,
                         Lineage},
                        {ScopeId, InvocationId} = Actor, Selection) ->
    controller_request(
      Handle, ControllerId, Actor, Selection,
      fun() -> quod_proof_context:tx_request(
                 Actor, {allocate, Lineage}) end,
      fun({ok, BatchId}) ->
              {savepoint_allocated, ControllerId, BatchId}
      end,
      ScopeId);
serve_remote_controller(Handle,
                        {savepoint_restore, ControllerId, InvocationId,
                         Lineage, BatchIds},
                        {ScopeId, InvocationId} = Actor, Selection) ->
    controller_request(
      Handle, ControllerId, Actor, Selection,
      fun() -> quod_proof_context:tx_request(
                 Actor, {restore, Lineage, BatchIds}) end,
      fun(ok) -> {savepoint_restored, ControllerId, BatchIds} end,
      ScopeId);
serve_remote_controller(_Handle, _Operation, _Actor, _Selection) ->
    {error, {protocol_error, unexpected_scope_command}}.

controller_request(Handle, ControllerId, Actor, Selection,
                   RequestFun, ReplyFun, ScopeId) ->
    case remote_controller_source(Handle, Actor, Selection) andalso
         ScopeId =:= quod_scope_session:scope_id(Handle) of
        false -> {error, not_allowed};
        true ->
            case RequestFun() of
                {error, Reason} ->
                    send_controller_reply(
                      Handle,
                      {controller_error, ControllerId,
                       public_controller_error(Reason)});
                Result ->
                    try send_controller_reply(Handle, ReplyFun(Result))
                    catch _:_ -> {error, {protocol_error, proof_engine}}
                    end
            end
    end.

remote_controller_source(Handle,
                         {ScopeId, _InvocationId} = Actor, Selection) ->
    ScopeId =:= quod_scope_session:scope_id(Handle) andalso
        quod_transaction_scope:valid_selection(Selection) andalso
        quod_proof_context:registered_invocation(
          Actor, quod_transaction_scope:selection_lineage(Selection)).

send_nested_advance_reply(Handle, ControllerId, ProxyId, Expected,
                          {solution, Solution, _Stream}) ->
    encoded_controller_reply(
      answer, Solution,
      fun(Blob) ->
          {nested_solution, ControllerId, ProxyId, Expected, Blob}
      end, Handle);
send_nested_advance_reply(Handle, ControllerId, ProxyId, Expected,
                          {complete, Reasons}) ->
    encoded_controller_reply(
      failure_reasons, Reasons,
      fun(Blob) ->
          {nested_complete, ControllerId, ProxyId, Expected, Blob}
      end, Handle);
send_nested_advance_reply(Handle, ControllerId, ProxyId, Expected,
                          {error, {erlog, Error}}) ->
    encoded_controller_reply(
      erlog_error, Error,
      fun(Blob) ->
          {nested_erlog_error, ControllerId, ProxyId, Expected, Blob}
      end, Handle);
send_nested_advance_reply(Handle, ControllerId, _ProxyId, _Expected,
                          {error, Reason}) ->
    send_controller_reply(
      Handle,
      {nested_error, ControllerId, public_controller_error(Reason)}).

encoded_controller_reply(Kind, Term, BuildReply, Handle) ->
    case quod_scope_wire:encode_payload(Kind, Term) of
        {ok, Blob} -> send_controller_reply(Handle, BuildReply(Blob));
        {error, Reason} -> {error, Reason}
    end.

send_controller_reply(Handle, Operation) ->
    case quod_ask_router:command(
           Handle, execution_remaining_ms(), Operation) of
        {sent, _RequestId} -> ok;
        {error, Reason} -> {error, Reason};
        _ -> {error, {protocol_error, proof_engine}}
    end.

public_controller_error(Reason) ->
    case Reason of
        bad_request -> {protocol_error, request_binding};
        not_allowed -> {protocol_error, request_binding};
        unknown_lineage -> {protocol_error, request_binding};
        unknown_savepoint -> {protocol_error, request_binding};
        active_child_transaction -> {protocol_error, request_binding};
        transaction_scope_mismatch -> {protocol_error, request_binding};
        broken_transaction_controller -> {protocol_error, request_binding};
        _ -> validated_controller_error(Reason)
    end.

validated_controller_error(Reason) ->
    case quod_scope_wire:valid_public_error(Reason) of
        true -> Reason;
        false -> {protocol_error, proof_engine}
    end.

serve_nested({proof_nested_open, ProofId, From, RequestRef,
              Actor, Selection, Target, Goal, Chain}) ->
    Reply =
        case valid_nested_source(ProofId, From, Actor, Selection) of
            true ->
                case origin_open(Target, Goal, Chain, Actor, Selection) of
                    {ok, {origin_scope_stream, Ref, 1}} -> {opened, Ref};
                    {error, Reason} -> {error, Reason}
                end;
            false -> {error, not_allowed}
        end,
    From ! {proof_nested_reply, ProofId, RequestRef, Reply},
    ok;
serve_nested({proof_nested_next, ProofId, From, RequestRef,
              Actor, Selection, Ref, Expected}) ->
    Reply =
        case valid_nested_source(ProofId, From, Actor, Selection) of
            true -> nested_origin_reply(
                      Expected,
                      origin_advance(Ref, Actor, Selection, Expected));
            false -> {error, not_allowed}
        end,
    From ! {proof_nested_reply, ProofId, RequestRef, Reply},
    ok;
serve_nested({proof_nested_cancel, ProofId, From, Actor, Selection, Ref}) ->
    case valid_nested_source(ProofId, From, Actor, Selection) of
        true ->
            case cancel_origin_proxy(Ref, Actor) of
                ok -> ok;
                {error, _Reason} -> ok
            end;
        false -> ok
    end.

serve_tx_request({proof_tx_request, ProofId, From, ScopeId, InvocationId,
                  RequestRef, Operation}) ->
    Actor = {ScopeId, InvocationId},
    Reply =
        case ProofId =:= quod_proof_context:proof_id() andalso
             scope_owned_by(ScopeId, From) of
            true -> quod_proof_context:tx_request(Actor, Operation);
            false -> {error, not_allowed}
        end,
    From ! {proof_tx_reply, ProofId, InvocationId, RequestRef, Reply},
    ok.

nested_origin_reply(Expected, {solution, Solution, _Stream}) ->
    {solution, Expected, Solution};
nested_origin_reply(Expected, {complete, Reasons}) ->
    {complete, Expected, Reasons};
nested_origin_reply(_Expected, {error, Reason}) ->
    {error, Reason}.

valid_nested_source(ProofId, From,
                    {ScopeId, _InvocationId} = Actor, Selection) ->
    ProofId =:= quod_proof_context:proof_id() andalso
        scope_owned_by(ScopeId, From) andalso
        quod_transaction_scope:valid_selection(Selection) andalso
        quod_proof_context:registered_invocation(
          Actor, quod_transaction_scope:selection_lineage(Selection));
valid_nested_source(_ProofId, _From, _Actor, _Selection) ->
    false.

scope_owned_by(ScopeId, Owner) when is_pid(Owner) ->
    case quod_proof_context:scope_owner(ScopeId) of
        {ok, Owner} -> true;
        _ -> false
    end;
scope_owned_by(_ScopeId, _Owner) ->
    false.

-ifdef(TEST).
test_serve_nested(Message) -> serve_nested(Message).
test_await_scope_reply(Handle, RequestRef) ->
    await_scope_reply(Handle, RequestRef, none).
-endif.

cancel_origin_proxy(Ref, Owner) ->
    case quod_proof_context:proxy(Ref, Owner) of
        {ok, Invocation} ->
            ok = close_stream(Invocation),
            ok = quod_proof_context:drop_proxy(Ref, Owner),
            ok;
        {error, Reason} -> {error, Reason}
    end.

request_nested_cancel(Origin, ProofId, Actor, Selection, Ref) ->
    Origin ! {proof_nested_cancel, ProofId, self(), Actor, Selection, Ref},
    ok.

session_metadata(St) ->
    try quod_proof_session:context(St)
    catch error:badarg -> undefined
    end.

publish_session(St) ->
    case session_metadata(St) of
        undefined -> St;
        _ -> ok = quod_proof_session:publish(St), St
    end.

refresh_session(St) ->
    case session_metadata(St) of
        undefined -> St;
        _ -> quod_proof_session:refresh(St)
    end.

checked_completion(Reasons) ->
    case erlog_int:merge_failure_reasons(Reasons, #est{}) of
        {ok, _} -> {complete, Reasons};
        error -> error
    end.

close_stream({scope_invocation, Handle, InvocationId,
              _Selection, _Seq}) ->
    _ = quod_scope_session:invoke_cancel(Handle, InvocationId),
    quod_proof_context:unregister_invocation(
      {quod_scope_session:scope_id(Handle), InvocationId});
close_stream({local_scope_invocation, ScopeId, Session, InvocationId,
              _Selection, _Seq}) ->
    try
        ok = quod_proof_session:cancel(Session, InvocationId)
    after
        quod_proof_context:unregister_invocation({ScopeId, InvocationId})
    end;
close_stream({origin_scope_stream, Ref, _Expected}) ->
    _ = try cancel_origin_proxy(
              Ref, quod_transaction_scope:current_actor())
        catch _:_ -> ok end,
    ok;
close_stream({nested_scope_stream, Origin, ProofId, Ref,
              Actor, Selection, _Expected}) ->
    request_nested_cancel(Origin, ProofId, Actor, Selection, Ref).


%% Every declared ontology on the path and the authenticated node principal must
%% be authorized. This prevents a peer laundering access through an invented chain.
%% Policies are proved against this ontology's committed KB.
-doc """
Prove the target's own `can_invoke/4` admission rule before a scope invocation.

The rule receives the canonical call chain **once**, as one list, rather than
being re-proved per chain member: a restrictive policy inspects or quantifies
the members itself, so it can express relations between them that a per-member
conjunction could not. `Principal` is the engine-owned `node(NodeKey)` term
derived from the authenticated link, never a value Prolog supplied.

The decision is proved on a strict read-only frame over the scope's pinned
**committed base**, so a proof cannot stage an authorization grant and consume
it in the same transaction. Its committed reads are absorbed into the scope's
own dependency set, making the policy a real OCC dependency of the plan this
scope seals.
""".
-spec authorize_scope({node, <<_:256>>} | anonymous,
                      term(), [quod_proof_context:identity()],
                      quod_proof_context:identity(), non_neg_integer(),
                      quod_proof_session:session()) -> boolean().
authorize_scope(Principal, Goal, Chain,
                {Ns, <<_:256>> = Anchor}, Height, Session)
  when Principal =:= anonymous orelse element(1, Principal) =:= node,
       is_list(Chain), is_binary(Ns), is_integer(Height), Height >= 0 ->
    Ctx = quod_predicates:proof_context(
            Ns, Height, undefined, [{Ns, Anchor} | Chain]),
    Committed = quod_predicates:set_context(
                  quod_proof_session:committed_state(Session), Ctx),
    Wrapped = quod_erlog_db_local_prove:wrap_state(
                Committed,
                #{read_set => true,
                  read_only => true,
                  %% Authorization is part of the same ontology access, not a
                  %% fresh snapshot that can outlive its parent session.
                  access_guard =>
                      quod_proof_session:access_guard(Session)}),
    #est{db = #db{ref = PolicyOverlay}} = Wrapped,
    try case authorization_goal(Ns, Goal, Principal, Chain) of
            {ok, PolicyGoal} -> prove_bool(PolicyGoal, Wrapped);
            error -> false
        end
    after
        %% The policy's committed reads belong to this scope's plan even when it
        %% refused: the refusal is itself a decision a later commit can falsify.
        %% `get_dependencies` also carries any live-bridge markers the policy
        %% recorded, so a bridge-dependent decision taints the plan it admitted.
        quod_proof_session:absorb_read_set(
          Session, quod_erlog_db_local_prove:get_dependencies(PolicyOverlay)),
        quod_erlog_db_local_prove:cleanup_read_set(Wrapped)
    end.

-doc """
Re-prove one target plan's recorded authorization decisions at Prepare.

The caller supplies the target's already-authenticated, owner-materialized
transcript.  Every row is checked against the exact parent state in a strict
local policy context: writes, ontology selection, following, and all governed
live bridges are unavailable.  A recorded denial must re-prove as an ordinary
logical failure; an interpreter error is invalid, not another kind of denial.
""".
-spec validate_authorization_transcript(
        quod_proof_context:identity(), quod_proof_context:identity(),
        quod_dtx:principal(), non_neg_integer(),
        [quod_dtx:transcript_entry()], tuple()) ->
          ok | {error, invalid_authorization_transcript}.
validate_authorization_transcript(
  {Ns, <<_:256>>} = Target, {_OriginNs, <<_:256>>} = Origin,
  Principal, ParentHeight, [_ | _] = Transcript, #est{} = ParentEst)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(ParentHeight), ParentHeight >= 0 ->
    case valid_authorization_principal(Principal) of
        true ->
            validate_authorization_entries(
              Transcript, Target, Origin, Principal, ParentHeight,
              ParentEst);
        false ->
            invalid_authorization_transcript()
    end;
validate_authorization_transcript(
  _Target, _Origin, _Principal, _ParentHeight, _Transcript, _ParentEst) ->
    invalid_authorization_transcript().

validate_authorization_entries(
  [], _Target, _Origin, _Principal, _ParentHeight, _ParentEst) ->
    ok;
validate_authorization_entries(
  [Entry | Rest], Target, Origin, Principal, ParentHeight, ParentEst) ->
    case validate_authorization_entry(
           Entry, Target, Origin, Principal, ParentHeight, ParentEst) of
        ok ->
            validate_authorization_entries(
              Rest, Target, Origin, Principal, ParentHeight, ParentEst);
        {error, invalid_authorization_transcript} = Error ->
            Error
    end;
validate_authorization_entries(
  _Improper, _Target, _Origin, _Principal, _ParentHeight, _ParentEst) ->
    invalid_authorization_transcript().

validate_authorization_entry(
  {<<_:128>>, FullChain, GoalBlob, Verdict, AnswerCount, <<_:256>>, Tag},
  {Ns, _Anchor} = Target, Origin, Principal, ParentHeight, ParentEst)
  when (Verdict =:= allowed orelse Verdict =:= denied),
       is_integer(AnswerCount), AnswerCount >= 0,
       AnswerCount =< ?QUOD_MAX_ANSWERS_PER_INVOCATION,
       (Tag =:= active orelse Tag =:= complete orelse
        Tag =:= error orelse Tag =:= cancelled) ->
    case {authorization_chain(FullChain, Target, Origin),
          quod_wire_term:decode_canonical(
            GoalBlob, ?QUOD_MAX_NESTED_GOAL_BYTES)} of
        {{ok, CallerChain}, {ok, Goal}} ->
            case fully_materialized(Goal) of
                true ->
                    reprove_authorization(
                      Ns, Goal, Principal, FullChain, CallerChain,
                      ParentHeight, Verdict, ParentEst);
                false ->
                    invalid_authorization_transcript()
            end;
        _ ->
            invalid_authorization_transcript()
    end;
validate_authorization_entry(
  _Entry, _Target, _Origin, _Principal, _ParentHeight, _ParentEst) ->
    invalid_authorization_transcript().

reprove_authorization(
  Ns, Goal, Principal, FullChain, CallerChain, ParentHeight, Verdict,
  ParentEst) ->
    Context = quod_predicates:with_chain(
                quod_predicates:policy_verdict_context(
                  Ns, ParentHeight), FullChain),
    Committed = quod_predicates:set_context(ParentEst, Context),
    Wrapped = quod_erlog_db_local_prove:wrap_state(
                Committed, #{read_only => true}),
    try case authorization_goal(Ns, Goal, Principal, CallerChain) of
            {ok, PolicyGoal} ->
                case strict_authorization_result(PolicyGoal, Wrapped) of
                    Verdict -> ok;
                    _ -> invalid_authorization_transcript()
                end;
            error ->
                invalid_authorization_transcript()
        end
    after
        quod_erlog_db_local_prove:cleanup_read_set(Wrapped)
    end.

authorization_chain([Target | Rest] = FullChain, Target, Origin) ->
    case chain_identities(FullChain, 0, [], undefined) of
        {ok, [_TargetNs | _CallerNamespaces], Origin} ->
            {ok, Rest};
        _ ->
            error
    end;
authorization_chain(_FullChain, _Target, _Origin) ->
    error.

chain_identities([], _Depth, NamespacesRev, Last) ->
    {ok, lists:reverse(NamespacesRev), Last};
chain_identities([{Ns, <<_:256>>} = Identity | Rest], Depth,
                 NamespacesRev, _Last)
  when is_binary(Ns), byte_size(Ns) > 0,
       Depth < ?QUOD_MAX_ACTIVE_PROOF_DEPTH ->
    chain_identities(Rest, Depth + 1, [Ns | NamespacesRev], Identity);
chain_identities(_ImproperOrTooDeep, _Depth, _NamespacesRev, _Last) ->
    error.

authorization_goal(Ns, Goal, Principal, Chain) ->
    case chain_identities(Chain, 0, [], undefined) of
        {ok, CallChain, _Last} ->
            {ok, {can_invoke, Goal, Principal, CallChain, Ns}};
        error ->
            error
    end.

valid_authorization_principal({node, <<_:256>>}) -> true;
valid_authorization_principal(anonymous) -> true;
valid_authorization_principal(_) -> false.

fully_materialized({'$quod_symbol', Binary}) when is_binary(Binary) -> false;
fully_materialized(Term) when is_tuple(Term) ->
    fully_materialized_tuple(Term, 1, tuple_size(Term));
fully_materialized([Head | Tail]) ->
    fully_materialized(Head) andalso fully_materialized(Tail);
fully_materialized([]) -> true;
fully_materialized(_Term) -> true.

fully_materialized_tuple(_Term, Index, Size) when Index > Size -> true;
fully_materialized_tuple(Term, Index, Size) ->
    fully_materialized(element(Index, Term)) andalso
        fully_materialized_tuple(Term, Index + 1, Size).

invalid_authorization_transcript() ->
    {error, invalid_authorization_transcript}.

strict_authorization_result(Goal, W) ->
    try authorization_result(Goal, W)
    catch
        _:_ -> invalid
    end.

prove_bool(Goal, W) ->
    case authorization_result(Goal, W) of
        allowed -> true;
        denied -> false;
        invalid -> false
    end.

authorization_result(Goal, W) ->
    try erlog_int:prove_goal(Goal, W) of
        {succeed, _} -> allowed;
        {fail, _} -> denied;
        _ -> invalid
    catch
        %% A generation/fence failure is infrastructure truth, not a policy
        %% denial. Preserve it so the calling ontology receives the same typed
        %% transaction_pending/rebuilding error as the target scope.
        throw:{quod_ask_error, Reason} ->
            throw({quod_ask_error, Reason});
        _:_ ->
            invalid
    end.
