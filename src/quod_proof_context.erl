-module(quod_proof_context).
-moduledoc """
Private coordination state for one top-level ontology proof.

The origin proof worker owns this state.  It pins ontology scopes, binds every
nested invocation to an exact `{ScopeId, InvocationId}` actor, and coordinates the
bounded logical savepoint batches used by distributed `transaction/1`.
Controller ids are proof-local 128-bit binaries; they never enter consensus or
the scope wire as Erlang references.
""".

-include("quod_proof_limits.hrl").

-export([start/6, stop/2, proof_id/0, origin_identity/0, principal/0,
         request_evidence/0, request_auth/0, request_binding/0,
         scope_authentication/0, ensure_scope_authentication/0,
         durable_bindings/1,
         read_only/0, deadline_ms/0, remaining_ms/0,
         finalize/1, seal_plans/0, scope_handle/1, select_independent/1, independent/0,
         bind_router/3,
         get_or_open_scope/2,
         scope_owner/1,
         register_invocation/2, unregister_invocation/1,
         registered_invocation/2,
         new_proxy/3, proxy/2, update_proxy/3, drop_proxy/2,
         mark_dirty/2,
         tx_request/2, materialize/2]).
-ifdef(TEST).
-export([start/5, scopes/0, registered_scope/1]).
-endif.

-type opaque_id() :: <<_:128>>.
-type scope_id() :: opaque_id().
-type actor() :: quod_transaction_scope:actor().

-record(scope, {id :: scope_id(),
                owner :: pid(),
                mref = undefined :: undefined | reference(),
                handle :: term()}).

-record(router, {pid :: pid(),
                 generation :: opaque_id(),
                 mref :: reference(),
                 target_ns :: binary()}).

-record(tx, {owner :: actor(),
             parent = none :: none | opaque_id(),
             batches = #{} :: #{opaque_id() => true}}).

-record(lineage, {parent = none :: quod_transaction_scope:lineage(),
                  tail = none :: none | opaque_id(),
                  tx_ids_rev = [] :: [opaque_id()]}).

-record(batch, {owners = #{} :: #{opaque_id() => true},
                local_owner :: scope_id(),
                materialized = #{} :: #{scope_id() => true}}).

-record(ctx, {proof_id  :: <<_:256>>,
              origin_identity :: identity(),
              principal :: quod_dtx:principal(),
              request_evidence = none :: none | quod_client_goal:evidence(),
              request_binding = none :: quod_client_goal:request_binding(),
              agent_identity = none ::
                  none | quod_agent_identity:certificate(),
              deadline_ms :: integer(),
              read_only = false :: boolean(),
              finalization = open :: open | ok | {error, term()},
              router = undefined :: undefined | #router{},
              scopes = #{} :: #{identity() => #scope{}},
              namespaces = #{} :: map(),
              scope_ids = #{} :: #{scope_id() => identity()},
              invocations = #{} :: #{actor() => quod_transaction_scope:lineage()},
              proxies = #{} :: map(),
              dirty = #{} :: map(),
              independent = false :: boolean(),
              txs = #{} :: #{opaque_id() => #tx{}},
              lineages = #{} :: #{opaque_id() => #lineage{}},
              batches = #{} :: #{opaque_id() => #batch{}},
              seal_result = open ::
                  (open | {ok, map()} | {error, term()})}).

-define(KEY, '$quod_proof_context').

-type identity() :: {binary(), <<_:256>>}.
-type handle() :: {quod_proof_context, <<_:256>>, pid()}.
-export_type([identity/0, handle/0]).

-ifdef(TEST).
-spec start(<<_:256>>, boolean(), identity(), integer(),
            quod_dtx:principal()) -> handle().
start(<<_:256>> = ProofId, ReadOnly,
      {Ns, <<_:256>>} = OriginIdentity, DeadlineMs, Principal)
  when is_boolean(ReadOnly), is_binary(Ns), is_integer(DeadlineMs) ->
    start(ProofId, ReadOnly, OriginIdentity, DeadlineMs, Principal, none).
-endif.

-spec start(<<_:256>>, boolean(), identity(), integer(),
            quod_dtx:principal(),
            none | quod_client_goal:evidence()) -> handle().
start(<<_:256>> = ProofId, ReadOnly,
      {Ns, <<_:256>>} = OriginIdentity, DeadlineMs, Principal, RequestEvidence)
  when is_boolean(ReadOnly), is_binary(Ns), is_integer(DeadlineMs) ->
    undefined = get(?KEY),
    put(?KEY, #ctx{proof_id = ProofId,
                   origin_identity = OriginIdentity,
                   principal = Principal,
                   request_evidence = RequestEvidence,
                   request_binding = request_binding_of(RequestEvidence),
                   deadline_ms = DeadlineMs,
                   read_only = ReadOnly}),
    {quod_proof_context, ProofId, self()}.

request_binding_of(none) -> none;
request_binding_of(Evidence) ->
    quod_client_goal:request_binding(quod_client_goal:request_auth(Evidence)).

-doc "Close all selected scopes and invocation proxies, then discard proof-local control state.".
-spec stop(fun((term()) -> term()), fun(({actor(), term()}) -> term())) -> ok.
stop(CloseScopeFun, CloseProxyFun)
  when is_function(CloseScopeFun, 1), is_function(CloseProxyFun, 1) ->
    quod_trace:with_span(
      quod_trace:context(), <<"quod.proof_context.cleanup">>, internal, #{},
      fun(_Span) ->
          case erase(?KEY) of
              #ctx{router = Router, scopes = Scopes, proxies = Proxies} ->
                  maps:foreach(
                    fun(_Ref, Proxy) ->
                        try CloseProxyFun(Proxy) catch _:_ -> ok end
                    end, Proxies),
                  maps:foreach(
                    fun(_Identity, #scope{handle = Scope, mref = MRef}) ->
                        try CloseScopeFun(Scope) catch _:_ -> ok end,
                        demonitor_scope(MRef)
                    end, Scopes),
                  demonitor_router(Router),
                  ok;
              undefined ->
                  ok
          end
      end).

-spec proof_id() -> <<_:256>>.
proof_id() -> (context())#ctx.proof_id.

-spec origin_identity() -> identity().
origin_identity() -> (context())#ctx.origin_identity.

-spec principal() -> quod_dtx:principal().
principal() -> (context())#ctx.principal.

-spec request_evidence() -> none | quod_client_goal:evidence().
request_evidence() -> (context())#ctx.request_evidence.

-spec request_auth() -> none | quod_client_goal:request_auth().
request_auth() ->
    case (context())#ctx.request_evidence of
        none -> none;
        Evidence -> quod_client_goal:request_auth(Evidence)
    end.

-spec request_binding() -> quod_client_goal:request_binding().
request_binding() -> (context())#ctx.request_binding.

%% Called only when the origin accepts its selected whole-proof solution.
%% Descendant replies first join the caller's binding trail; they never set this.
-spec select_independent(boolean()) -> ok | {error, independent_requires_signed_request}.
select_independent(Selected) when is_boolean(Selected) ->
    Ctx = context(),
    open = Ctx#ctx.seal_result,
    case Selected andalso Ctx#ctx.request_evidence =:= none of
        true -> {error, independent_requires_signed_request};
        false -> put_context(Ctx#ctx{independent = Selected}), ok
    end.

-spec independent() -> boolean().
independent() -> (context())#ctx.independent.

-doc "Return the one scope-wire authentication object for this proof.".
-spec scope_authentication() -> quod_scope_wire:authentication().
scope_authentication() ->
    case {(context())#ctx.request_evidence,
          (context())#ctx.agent_identity} of
        {none, none} -> node;
        {#{request_bytes := Bytes, signature := Signature}, Certificate}
          when Certificate =/= none ->
            {signed_goal, Bytes, Signature, Certificate}
    end.

-doc "Acquire the proof-scoped certificate before its first remote scope.".
-spec ensure_scope_authentication() ->
          {ok, quod_scope_wire:authentication()} | {error, term()}.
ensure_scope_authentication() ->
    quod_trace:with_span(
      quod_trace:context(), <<"quod.scope.authentication_material">>,
      internal, #{},
      fun(SpanCtx) ->
          Result = ensure_scope_authentication_inner(),
          _ = quod_trace:result(SpanCtx, Result),
          Result
      end).

ensure_scope_authentication_inner() ->
    Ctx0 = context(),
    case {Ctx0#ctx.request_evidence, Ctx0#ctx.agent_identity} of
        {none, none} -> {ok, node};
        {#{}, Certificate} when Certificate =/= none ->
            {ok, scope_authentication()};
        {Evidence = #{}, none} ->
            Started = erlang:monotonic_time(),
            Result = case quod_ask_router:identity(
                            Evidence, Ctx0#ctx.proof_id, remaining_ms()) of
                         {ok, Certificate} ->
                             install_agent_identity(Certificate);
                         {pending, Router, Generation, Ref} ->
                             await_agent_identity(
                               Router, Generation, Ref,
                               element(1, Ctx0#ctx.origin_identity));
                         {error, _} = Error -> Error
                     end,
            ok = quod_metrics:observe_remote_operation_stage(
                   element(1, Ctx0#ctx.origin_identity),
                   identity_certificate, metric_result(Result),
                   erlang:monotonic_time() - Started),
            Result
    end.

metric_result({ok, _}) -> ok;
metric_result({error, timeout}) -> uncertain;
metric_result({error, unavailable}) -> uncertain;
metric_result({error, retry}) -> uncertain;
metric_result({error, _}) -> failed.

await_agent_identity(Router, Generation, Ref, OriginNs) ->
    case bind_router(Router, Generation, OriginNs) of
        {ok, MRef} ->
            receive
                {quod_agent_identity, Ref, {ok, Certificate}} ->
                    install_agent_identity(Certificate);
                {quod_agent_identity, Ref, {error, Reason}} ->
                    {error, Reason};
                {'DOWN', MRef, process, Router, _Reason} ->
                    {error, unavailable}
            after remaining_ms() ->
                {error, timeout}
            end;
        {error, _} = Error -> Error
    end.

install_agent_identity(Certificate) ->
    case quod_agent_identity:validate_certificate(Certificate) of
        true ->
            put_context((context())#ctx{agent_identity = Certificate}),
            {ok, scope_authentication()};
        false -> {error, {protocol_error, request_binding}}
    end.

-doc "Give a committed result the stable variable names verified at ingress.".
-spec durable_bindings(map()) -> {ok, map()} | {error, invalid_result}.
durable_bindings(Bindings) when is_map(Bindings) ->
    case (context())#ctx.request_evidence of
        none -> {ok, Bindings};
        Evidence -> quod_client_goal:durable_bindings(Evidence, Bindings)
    end;
durable_bindings(_Bindings) ->
    {error, invalid_result}.

-spec read_only() -> boolean().
read_only() -> (context())#ctx.read_only.

-doc "Absolute engine-assigned proof deadline on this node's monotonic clock.".
-spec deadline_ms() -> integer().
deadline_ms() -> (context())#ctx.deadline_ms.

-doc "Remaining engine-assigned proof lifetime; scope commands cannot renew it.".
-spec remaining_ms() -> non_neg_integer().
remaining_ms() ->
    erlang:max(0, (context())#ctx.deadline_ms - quod_time:mono_ms()).

-doc """
Fence and detach every selected local or remote scope.

`commit` seals first (`m:quod_dtx`): while every scope is still live, each one
holding a staged diff or a non-empty influencing read set is sealed into a
signed local plan. `abort` never seals work that cannot commit; it only closes
the scopes so their private revisions are discarded. Closing always runs. A
commit-side seal failure takes precedence over a close failure.
""".
-spec finalize(commit | abort) -> ok | {error, term()}.
finalize(Mode) when Mode =:= commit; Mode =:= abort ->
    quod_trace:with_span(
      quod_trace:context(), <<"quod.proof_context.finalize">>, internal, #{},
      fun(_Span) ->
          Ctx0 = context(),
          case Ctx0#ctx.finalization of
              open ->
                  SealResult = finalize_seal(Mode),
                  %% Re-fetch: sealing may have bound the router meanwhile.
                  Ctx1 = context(),
                  CloseResult = finalize_scopes(
                                  Ctx1#ctx.scopes, Ctx1#ctx.router,
                                  Ctx1#ctx.proof_id),
                  Result = case SealResult of
                               ok -> CloseResult;
                               {error, _} -> SealResult
                           end,
                  put_context((context())#ctx{finalization = Result}),
                  Result;
              Result -> Result
          end
      end).

finalize_seal(commit) ->
    case seal_plans() of
        {ok, _Plans} -> ok;
        {error, _} = Error -> Error
    end;
finalize_seal(abort) ->
    ok.

-doc """
Seal every material scope's plan now, while all scopes are still open.

Idempotent within one proof: the submission stage seals before routing the
sealed plan set, and a later `finalize(commit)` reuses that same set rather than
sealing twice.
""".
-spec seal_plans() -> {ok, #{identity() => quod_dtx:plan()}} | {error, term()}.
seal_plans() ->
    Ctx0 = context(),
    case {Ctx0#ctx.finalization, Ctx0#ctx.seal_result} of
        {open, {ok, Plans}} ->
            {ok, Plans};
        {open, {error, _} = Error} ->
            Error;
        {open, open} ->
            {SealResult, Plans} = quod_trace:with_span(
              quod_trace:context(), <<"quod.proof_context.seal">>, internal,
              #{}, fun(_Span) -> seal_material_scopes(Ctx0) end),
            case SealResult of
                ok ->
                    Result = {ok, Plans},
                    put_context((context())#ctx{seal_result = Result}),
                    Result;
                {error, _} = Error ->
                    put_context((context())#ctx{seal_result = Error}),
                    Error
            end;
        {_Finalized, _} ->
            {error, proof_finalized}
    end.

-doc "The live scope handle pinned for one exact ontology identity.".
-spec scope_handle(identity()) -> {ok, term()} | error.
scope_handle(Identity) ->
    case maps:find(Identity, (context())#ctx.scopes) of
        {ok, #scope{handle = Handle}} -> {ok, Handle};
        error -> error
    end.

seal_material_scopes(#ctx{read_only = true}) ->
    {ok, #{}};
seal_material_scopes(#ctx{scopes = Scopes, dirty = Dirty,
                          origin_identity = OriginIdentity,
                          principal = Principal,
                          request_binding = RequestBinding}) ->
    case proof_material(Scopes, Dirty, RequestBinding) of
        {ok, false} -> {ok, #{}};
        {ok, true} -> seal_scopes(lists:sort(maps:to_list(Scopes)),
                                  OriginIdentity, Principal,
                                  RequestBinding, #{}, 0);
        {error, _} = Error -> {Error, #{}}
    end.

%% Plans exist to carry writes: only a proof that staged at least one write
%% anywhere seals, and then every scope it read from participates — an
%% empty-diff scope's read set is exactly what the eventual commit depends on.
proof_material(_Scopes, _Dirty, {agent_goal_v1, <<_:256>>}) ->
    %% Execute/Accept requests are durable operations even if their goal's
    %% database mutation is already present. The origin plan carries that one
    %% claim; untouched foreign scopes still seal to `not_material`.
    {ok, true};
proof_material(Scopes, Dirty, none) ->
    case lists:any(fun(Value) -> Value =:= true end, maps:values(Dirty)) of
        true -> {ok, true};
        false -> local_scope_material(maps:values(Scopes))
    end;
proof_material(_Scopes, _Dirty, _MalformedBinding) ->
    {error, invalid_request_binding}.

local_scope_material(
  [#scope{handle = {local_scope, _ScopeId, _Ns, _Anchor,
                    _Height, Session}} | Rest]) ->
    try quod_proof_session:dirty(Session) of
        true -> {ok, true};
        false -> local_scope_material(Rest)
    catch
        throw:{quod_ask_error, Reason} -> {error, Reason}
    end;
local_scope_material([#scope{} | Rest]) ->
    local_scope_material(Rest);
local_scope_material([]) ->
    {ok, false}.

seal_scopes([], _OriginIdentity, _Principal, _RequestBinding, Plans, Mask) ->
    %% Provenance can veto an independent route, never revive discarded intent.
    %% Ordinary fallback commits all retained material atomically, even mask 3.
    case independent() andalso (Mask band 1) =/= 0 of
        true -> {{error, independent_mixed_writes}, Plans};
        false -> {ok, Plans}
    end;
seal_scopes([{Identity, #scope{handle = Handle}} | Rest],
            OriginIdentity, Principal, RequestBinding, Plans, Mask) ->
    case quod_scope_session:seal(
           Handle, OriginIdentity, Principal, RequestBinding) of
        {ok, Plan, Provenance} ->
            seal_scopes(
              Rest, OriginIdentity, Principal, RequestBinding,
              Plans#{Identity => Plan}, Mask bor Provenance);
        not_material ->
            seal_scopes(
              Rest, OriginIdentity, Principal, RequestBinding, Plans, Mask);
        {error, _} = Error ->
            {Error, Plans}
    end.

finalize_scopes(Scopes, Router, ProofId) ->
    LocalResults = maps:fold(
                     fun(_Identity, Scope, Acc) ->
                         case finalize_local_scope(Scope) of
                             skipped -> Acc;
                             Result -> [Result | Acc]
                     end
                     end, [], Scopes),
    Results = finalize_router(Router, ProofId, LocalResults),
    finalization_result(Results).

finalize_router(undefined, _ProofId, Results) ->
    Results;
finalize_router(#router{pid = Router, target_ns = TargetNs}, ProofId, Results) ->
    [normalize_router_finalization(
       quod_ask_router:finalize(Router, ProofId), TargetNs) | Results].

normalize_router_finalization({error, unavailable}, TargetNs) ->
    {error, {ontology_unreachable, TargetNs}};
normalize_router_finalization({error, {scope_error, Reason}}, TargetNs) ->
    normalize_bound_router_error(Reason, TargetNs);
normalize_router_finalization({error, Reason}, TargetNs) ->
    normalize_bound_router_error(Reason, TargetNs);
normalize_router_finalization(ok, _TargetNs) -> ok.

normalize_bound_router_error(Reason, TargetNs) ->
    {error, quod_scope_wire:normalize_public_error(Reason, TargetNs)}.

finalize_local_scope(
  #scope{owner = Pid, mref = MRef,
         handle = {quod_scope_session, Pid, _ScopeId, _ProofId,
                   _SessionRef, _Ns, _Anchor} = Handle})
  when is_reference(MRef) ->
    case erlang:is_process_alive(Pid) of
        true ->
            %% The liveness check is this local scope's final linearization
            %% point.  Closing immediately prevents any later use; a death
            %% after the check belongs to cleanup, not to the sealed proof.
            quod_scope_session:close(Handle);
        false ->
            receive
                {'DOWN', MRef, process, Pid, Reason} ->
                    local_scope_down(Reason)
            end
    end;
finalize_local_scope(#scope{}) -> skipped.

local_scope_down({scope_error, Reason}) -> {error, Reason};
local_scope_down(_Reason) ->
    {error, {protocol_error, proof_engine}}.

finalization_result(Results) ->
    case lists:sort([Error || {error, _} = Error <- Results]) of
        [Error | _] -> Error;
        [] -> ok
    end.

-doc "Bind this proof to one exact router process and volatile generation.".
-spec bind_router(pid(), opaque_id(), binary()) ->
          {ok, reference()} | {error, term()}.
bind_router(Router, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = Generation,
            TargetNs)
  when is_pid(Router), is_binary(TargetNs), byte_size(TargetNs) > 0 ->
    Ctx0 = context(),
    case {Ctx0#ctx.finalization, Ctx0#ctx.router} of
        {open, undefined} ->
            MRef = monitor(process, Router),
            put_context(Ctx0#ctx{
                          router = #router{pid = Router,
                                           generation = Generation,
                                           mref = MRef,
                                           target_ns = TargetNs}}),
            {ok, MRef};
        {open, #router{pid = Router, generation = Generation,
                       mref = MRef, target_ns = Existing} = Bound} ->
            put_context(Ctx0#ctx{
                          router = Bound#router{
                                     target_ns = erlang:min(Existing, TargetNs)}}),
            {ok, MRef};
        {open, #router{pid = Router}} ->
            {error, {protocol_error, session_binding}};
        {open, #router{}} ->
            {error, {ontology_unreachable, TargetNs}};
        {_Finalized, _} ->
            {error, proof_finalized}
    end;
bind_router(_Router, _Generation, _TargetNs) ->
    {error, {protocol_error, session_binding}}.

demonitor_router(#router{mref = MRef}) ->
    demonitor(MRef, [flush]),
    ok;
demonitor_router(undefined) ->
    ok.

-doc "Return an existing pinned scope or open and register it exactly once.".
-spec get_or_open_scope(identity(), fun((scope_id()) ->
                                               {ok, pid(), term()} |
                                               {error, term()})) ->
          {ok, scope_id(), term()} | {error, term()}.
get_or_open_scope({Ns, <<_:256>> = Anchor} = Identity, OpenFun)
  when is_binary(Ns), is_function(OpenFun, 1) ->
    Ctx0 = context(),
    case Ctx0#ctx.finalization of
        open -> get_or_open_active_scope(Identity, Ns, Anchor, OpenFun, Ctx0);
        _ -> {error, proof_finalized}
    end.

get_or_open_active_scope(Identity, Ns, Anchor, OpenFun, Ctx0) ->
    case maps:find(Identity, Ctx0#ctx.scopes) of
        {ok, #scope{id = ScopeId, handle = Scope}} ->
            {ok, ScopeId, Scope};
        error ->
            case maps:find(Ns, Ctx0#ctx.namespaces) of
                {ok, OtherAnchor} when OtherAnchor =/= Anchor ->
                    {error, {anchor_conflict, Ns}};
                _ when map_size(Ctx0#ctx.scopes) >= ?QUOD_MAX_SCOPES_PER_PROOF ->
                    {error, {scope_limit_exceeded,
                             ?QUOD_MAX_SCOPES_PER_PROOF}};
                _ ->
                    open_scope(Identity, Ns, Anchor, OpenFun, Ctx0)
            end
    end.

open_scope(Identity, Ns, Anchor, OpenFun, Ctx0) ->
    ScopeId = new_scope_id(Ctx0),
    case OpenFun(ScopeId) of
        {ok, Pid, Scope} when is_pid(Pid) ->
            MRef = monitor_scope(Pid, Scope),
            Scopes1 = (Ctx0#ctx.scopes)#{
                        Identity => #scope{id = ScopeId,
                                           owner = Pid,
                                           mref = MRef,
                                           handle = Scope}},
            Namespaces1 = (Ctx0#ctx.namespaces)#{Ns => Anchor},
            ScopeIds1 = (Ctx0#ctx.scope_ids)#{ScopeId => Identity},
            put_context(Ctx0#ctx{scopes = Scopes1,
                                 namespaces = Namespaces1,
                                 scope_ids = ScopeIds1}),
            {ok, ScopeId, Scope};
        {error, _} = Error ->
            Error;
        _ ->
            {error, {protocol_error, proof_engine}}
    end.

monitor_scope(
  Pid, {quod_scope_session, Pid, _ScopeId, _ProofId,
        _SessionRef, _Ns, _Anchor}) ->
    monitor(process, Pid);
monitor_scope(_Pid, _Scope) -> undefined.

demonitor_scope(MRef) when is_reference(MRef) ->
    demonitor(MRef, [flush]),
    ok;
demonitor_scope(undefined) -> ok.

-spec scope_owner(scope_id()) -> {ok, pid()} | {error, not_allowed}.
scope_owner(<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = ScopeId) ->
    Ctx = context(),
    case maps:find(ScopeId, Ctx#ctx.scope_ids) of
        {ok, Identity} ->
            case maps:find(Identity, Ctx#ctx.scopes) of
                {ok, #scope{owner = Owner}} -> {ok, Owner};
                error -> {error, not_allowed}
            end;
        error -> {error, not_allowed}
    end;
scope_owner(_) ->
    {error, not_allowed}.

-ifdef(TEST).
-spec registered_scope(scope_id()) -> boolean().
registered_scope(<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = ScopeId) ->
    maps:is_key(ScopeId, (context())#ctx.scope_ids);
registered_scope(_) -> false.

-spec scopes() -> [term()].
scopes() -> [Scope || #scope{handle = Scope} <-
                          maps:values((context())#ctx.scopes)].
-endif.

-doc "Bind one live target invocation to its validated transaction selection.".
-spec register_invocation(actor(), quod_transaction_scope:selection()) ->
          ok | {error, term()}.
register_invocation(
  {ScopeId, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor, Selection)
  when is_binary(ScopeId),
       byte_size(ScopeId) =:= ?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8 ->
    Ctx0 = context(),
    ValidSelection = quod_transaction_scope:valid_selection(Selection),
    Lineage = case ValidSelection of
                  true -> quod_transaction_scope:selection_lineage(Selection);
                  false -> invalid
              end,
    case {ValidSelection, registered_in(Ctx0, ScopeId),
          lineage_exists(Lineage, Ctx0),
          maps:is_key(Actor, Ctx0#ctx.invocations)} of
        {false, _, _, _} -> {error, bad_request};
        {_, false, _, _} -> {error, not_allowed};
        {_, _, false, _} -> {error, unknown_lineage};
        {true, true, true, true} -> {error, already_registered};
        {true, true, true, false} ->
            put_context(Ctx0#ctx{
                          invocations = (Ctx0#ctx.invocations)#{Actor => Lineage}}),
            ok
    end;
register_invocation(_Actor, _Lineage) ->
    {error, bad_request}.

-spec unregister_invocation(actor()) -> ok.
unregister_invocation(
  {<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>,
   <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor) ->
    Ctx0 = context(),
    put_context(Ctx0#ctx{
                  invocations = maps:remove(Actor, Ctx0#ctx.invocations)});
unregister_invocation(_Actor) ->
    ok.

-doc "Whether the exact actor may execute at this base or owned descendant lineage.".
-spec registered_invocation(actor(), quod_transaction_scope:lineage()) -> boolean().
registered_invocation(Actor, Lineage) ->
    valid_actor(Actor) andalso
        invocation_authorized(Actor, Lineage, context()).

-doc "Create an origin-owned stream proxy bound to one exact invocation actor.".
-spec new_proxy(actor(), binary(), term()) ->
          {ok, opaque_id()} |
          {error, not_allowed | {proof_limit_exceeded, binary()}}.
new_proxy({ScopeId, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Owner,
          Target, Stream)
  when is_binary(ScopeId),
       byte_size(ScopeId) =:= ?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8,
       is_binary(Target) ->
    Ctx0 = context(),
    case maps:is_key(Owner, Ctx0#ctx.invocations) of
        false -> {error, not_allowed};
        true when map_size(Ctx0#ctx.proxies) >= ?QUOD_MAX_PROXIES_PER_PROOF ->
            {error, {proof_limit_exceeded, Target}};
        true ->
            Ref = new_proxy_id(Ctx0#ctx.proxies),
            put_context(Ctx0#ctx{proxies =
                                   (Ctx0#ctx.proxies)#{Ref => {Owner, Stream}}}),
            {ok, Ref}
    end;
new_proxy(_Owner, _Target, _Stream) ->
    {error, not_allowed}.

-spec proxy(opaque_id(), actor()) ->
          {ok, term()} | {error, not_allowed | unknown_proxy}.
proxy(<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = Ref, Owner) ->
    Ctx = context(),
    case {maps:is_key(Owner, Ctx#ctx.invocations),
          maps:find(Ref, Ctx#ctx.proxies)} of
        {false, _} -> {error, not_allowed};
        {true, {ok, {Owner, Stream}}} when is_tuple(Owner) -> {ok, Stream};
        {true, {ok, _}} -> {error, not_allowed};
        {true, error} -> {error, unknown_proxy}
    end.

-spec update_proxy(opaque_id(), actor(), term()) ->
          ok | {error, not_allowed | unknown_proxy}.
update_proxy(Ref, Owner, Stream) ->
    case proxy(Ref, Owner) of
        {ok, _Old} ->
            Ctx0 = context(),
            put_context(Ctx0#ctx{proxies =
                                   (Ctx0#ctx.proxies)#{Ref => {Owner, Stream}}});
        {error, _} = Error -> Error
    end.

-spec drop_proxy(opaque_id(), actor()) ->
          ok | {error, not_allowed | unknown_proxy}.
drop_proxy(Ref, Owner) ->
    case proxy(Ref, Owner) of
        {ok, _Stream} ->
            Ctx0 = context(),
            put_context(Ctx0#ctx{proxies = maps:remove(Ref, Ctx0#ctx.proxies)});
        {error, _} = Error -> Error
    end.

-spec mark_dirty(scope_id(), boolean()) -> ok | {error, not_allowed}.
mark_dirty(<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = ScopeId, Dirty)
  when is_boolean(Dirty) ->
    Ctx0 = context(),
    case maps:is_key(ScopeId, Ctx0#ctx.scope_ids) of
        false -> {error, not_allowed};
        true ->
            put_context(Ctx0#ctx{
                          dirty = (Ctx0#ctx.dirty)#{ScopeId => Dirty}})
    end.

-doc "Apply one authorized transaction-controller operation atomically.".
-spec tx_request(actor(), term()) -> term().
tx_request({ScopeId, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor,
           {activate, ParentLineage, FrameIds})
  when is_binary(ScopeId), is_list(FrameIds) ->
    activate_transactions(Actor, ParentLineage, FrameIds, context());
tx_request({ScopeId, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor,
           {allocate, Lineage}) when is_binary(ScopeId) ->
    allocate_batch(Actor, Lineage, context());
tx_request({ScopeId, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor,
           {restore, Lineage, BatchIds})
  when is_binary(ScopeId), is_list(BatchIds) ->
    restore_batches(Actor, Lineage, BatchIds, context());
tx_request({ScopeId, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor,
           {finish, Lineage, TxId}) when is_binary(ScopeId) ->
    finish_transaction(Actor, Lineage, TxId, context());
tx_request({ScopeId, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor,
           {discard, Lineage, TxId}) when is_binary(ScopeId) ->
    finish_transaction(Actor, Lineage, TxId, context());
tx_request(_Actor, _Operation) ->
    {error, bad_request}.

-doc "Lazily checkpoint the exact live selection on this target actor's scope.".
-spec materialize(quod_transaction_scope:selection(), actor()) ->
          ok | {error, term()}.
materialize({tx_selection, Lineage, BatchIds, _Mode} = Selection,
            {ScopeId, <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>} = Actor)
  when is_binary(ScopeId),
       byte_size(ScopeId) =:= ?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8 ->
    Ctx0 = context(),
    case bounded_unique_ids(BatchIds) of
        {error, limit} ->
            {error,
             {savepoint_limit_exceeded,
              ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}};
        {error, _} ->
            {error, bad_request};
        {ok, _Count} ->
            materialize_validated_selection(
              Selection, Lineage, BatchIds, Actor, ScopeId, Ctx0)
    end;
materialize(_Lineage, _Actor) ->
    {error, bad_request}.

materialize_validated_selection(Selection, Lineage, BatchIds, Actor, ScopeId,
                                Ctx0) ->
    case {quod_transaction_scope:valid_selection(Selection),
          invocation_authorized(Actor, Lineage, Ctx0)} of
        {false, _} -> {error, bad_request};
        {_, false} -> {error, not_allowed};
        {true, true} ->
            TxSet = lineage_tx_set(Lineage, Ctx0),
            case selection_batches_valid(BatchIds, TxSet, Ctx0) of
                false -> {error, unknown_savepoint};
                true ->
                    Missing =
                        [BatchId || BatchId <- BatchIds,
                          begin
                              #batch{local_owner = LocalOwner,
                                     materialized = Materialized} =
                                  maps:get(BatchId, Ctx0#ctx.batches),
                              LocalOwner =/= ScopeId andalso
                                  not maps:is_key(ScopeId, Materialized)
                          end],
                    materialize_missing(
                      ScopeId, Missing, Actor, Lineage, Ctx0)
            end
    end.

selection_batches_valid(BatchIds, TxSet, Ctx) ->
    lists:all(
      fun(BatchId) ->
          case maps:find(BatchId, Ctx#ctx.batches) of
              {ok, #batch{owners = Owners}} -> owners_within(Owners, TxSet);
              error -> false
          end
      end, BatchIds).

materialize_missing(_ScopeId, [], _Actor, _Lineage, _Ctx) -> ok;
materialize_missing(ScopeId, BatchIds, Actor, Lineage, Ctx0) ->
    case scope_for_id(ScopeId, Ctx0) of
        {ok, Scope} ->
            case quod_scope_session:materialize(
                   Scope, Actor, Lineage, BatchIds) of
                {ok, Dirty, _Generation} ->
                    Batches1 = lists:foldl(
                                 fun(BatchId, Acc) ->
                                     Batch = maps:get(BatchId, Acc),
                                     Acc#{BatchId => Batch#batch{
                                       materialized =
                                         (Batch#batch.materialized)#{ScopeId => true}}}
                                 end, Ctx0#ctx.batches, BatchIds),
                    Ctx1 = update_dirty(ScopeId, Dirty,
                                        Ctx0#ctx{batches = Batches1}),
                    put_context(Ctx1);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

activate_transactions(Actor, ParentLineage, FrameIds, Ctx0) ->
    case bounded_unique_ids(FrameIds) of
        {ok, 0} ->
            {error, bad_request};
        {error, limit} ->
            {error,
             {savepoint_limit_exceeded,
              ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}};
        {error, _} ->
            {error, bad_request};
        {ok, Count} ->
            activate_transactions_validated(
              Actor, ParentLineage, FrameIds, Count, Ctx0)
    end.

activate_transactions_validated(Actor, ParentLineage, FrameIds, Count, Ctx0) ->
    case valid_activation(Actor, ParentLineage, Count, Ctx0) of
        ok ->
            BaselineId = new_id(Ctx0),
            {ParentTail, ParentTxsRev} = lineage_tail_and_txs(ParentLineage, Ctx0),
            {Ctx1, _Tail, _Lineage, _TxsRev, ResponsesRev, Owners} =
                lists:foldl(
                  fun(FrameId, {Ctx, PriorTail, PriorLineage, PriorTxsRev,
                                Responses, Own}) ->
                      TxId = new_id(Ctx, [BaselineId]),
                      LineageId = new_id(Ctx, [BaselineId, TxId]),
                      Tx = #tx{owner = Actor, parent = PriorTail,
                               batches = #{BaselineId => true}},
                      TxsRev = [TxId | PriorTxsRev],
                      L = #lineage{parent = PriorLineage,
                                   tail = TxId, tx_ids_rev = TxsRev},
                      Txs = (Ctx#ctx.txs)#{TxId => Tx},
                      Lineages = (Ctx#ctx.lineages)#{LineageId => L},
                      {Ctx#ctx{txs = Txs, lineages = Lineages},
                       TxId, LineageId, TxsRev,
                       [{FrameId, TxId, LineageId, BaselineId} | Responses],
                       Own#{TxId => true}}
                  end,
                  {Ctx0, ParentTail, ParentLineage, ParentTxsRev, [], #{}},
                  FrameIds),
            Responses = lists:reverse(ResponsesRev),
            {_, _, FinalLineage, _} = lists:last(Responses),
            Batch = #batch{owners = Owners,
                           local_owner = element(1, Actor)},
            put_context(Ctx1#ctx{batches =
                                   (Ctx1#ctx.batches)#{BaselineId => Batch}}),
            {ok, FinalLineage, Responses};
        {error, _} = Error -> Error
    end.

valid_activation(Actor, ParentLineage, Count, Ctx) ->
    Limit = ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF,
    case {invocation_authorized(Actor, ParentLineage, Ctx),
          map_size(Ctx#ctx.txs) + Count =< Limit,
          map_size(Ctx#ctx.lineages) + Count =< Limit,
          map_size(Ctx#ctx.batches) + 1 =< Limit} of
        {false, _, _, _} -> {error, not_allowed};
        {_, false, _, _} -> {error, {savepoint_limit_exceeded, Limit}};
        {_, _, false, _} -> {error, {savepoint_limit_exceeded, Limit}};
        {_, _, _, false} -> {error, {savepoint_limit_exceeded, Limit}};
        {true, true, true, true} -> ok
    end.

allocate_batch(Actor, Lineage, Ctx0) ->
    Limit = ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF,
    case {Lineage =/= none, invocation_authorized(Actor, Lineage, Ctx0),
          map_size(Ctx0#ctx.batches) + 1 =< Limit} of
        {false, _, _} -> {error, bad_request};
        {_, false, _} -> {error, not_allowed};
        {_, _, false} -> {error, {savepoint_limit_exceeded, Limit}};
        {true, true, true} ->
            BatchId = new_id(Ctx0),
            TxIds = lineage_tx_ids(Lineage, Ctx0),
            Owners = maps:from_keys(TxIds, true),
            Batch = #batch{owners = Owners,
                           local_owner = element(1, Actor)},
            Txs1 = lists:foldl(
                     fun(TxId, Acc) ->
                         Tx = maps:get(TxId, Acc),
                         Acc#{TxId => Tx#tx{
                           batches = (Tx#tx.batches)#{BatchId => true}}}
                     end, Ctx0#ctx.txs, TxIds),
            put_context(Ctx0#ctx{txs = Txs1,
                                 batches = (Ctx0#ctx.batches)#{BatchId => Batch}}),
            {ok, BatchId}
    end.

restore_batches(Actor, Lineage, BatchIds0, Ctx0) when is_list(BatchIds0) ->
    case bounded_unique_ids(BatchIds0) of
        {error, limit} ->
            {error,
             {savepoint_limit_exceeded,
              ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}};
        {error, _} ->
            {error, bad_request};
        {ok, _Count} ->
            BatchIds = lists:sort(BatchIds0),
            restore_validated_batches(Actor, Lineage, BatchIds, Ctx0)
    end;
restore_batches(_Actor, _Lineage, _BatchIds, _Ctx) ->
    {error, bad_request}.

restore_validated_batches(Actor, Lineage, BatchIds, Ctx0) ->
    case invocation_authorized(Actor, Lineage, Ctx0) of
        false -> {error, not_allowed};
        true ->
            TxSet = lineage_tx_set(Lineage, Ctx0),
            case batches_restorable(BatchIds, element(1, Actor), TxSet, Ctx0) of
                false -> {error, unknown_savepoint};
                true ->
                    Groups = batch_groups(BatchIds, Ctx0),
                    case apply_groups(restore, Groups, Ctx0) of
                        {ok, Ctx1} -> put_context(Ctx1);
                        {error, Reason, Ctx1} ->
                            put_context(Ctx1),
                            {error, Reason}
                    end
            end
    end.

batches_restorable(BatchIds, OwnerPid, TxSet, Ctx) ->
    lists:all(
      fun(BatchId) ->
          case maps:find(BatchId, Ctx#ctx.batches) of
              {ok, #batch{local_owner = OwnerPid, owners = Owners}} ->
                  owners_within(Owners, TxSet);
              _ -> false
          end
      end, BatchIds).

finish_transaction(Actor, Lineage, TxId, Ctx0) ->
    case finish_preflight(Actor, Lineage, TxId, Ctx0) of
        {ok, #tx{batches = TxBatches}, ParentLineage} ->
            {Batches1, Orphans} = detach_owner(
                                    TxId, maps:keys(TxBatches),
                                    Ctx0#ctx.batches, []),
            OrphanIds = [BatchId || {BatchId, _Batch} <- Orphans],
            Groups = batch_groups_from_records(Orphans),
            case apply_groups(release, Groups, Ctx0) of
                {ok, Ctx1} ->
                    Invocations1 = maps:filter(
                                     fun(_InvocationActor, BaseLineage) ->
                                         BaseLineage =/= Lineage
                                     end, Ctx1#ctx.invocations),
                    Proxies1 = maps:filter(
                                 fun(_Ref, {Owner, _Stream}) ->
                                     maps:is_key(Owner, Invocations1)
                                 end, Ctx1#ctx.proxies),
                    put_context(Ctx1#ctx{
                                  invocations = Invocations1,
                                  proxies = Proxies1,
                                  txs = maps:remove(TxId, Ctx1#ctx.txs),
                                  lineages = maps:remove(Lineage,
                                                         Ctx1#ctx.lineages),
                                  batches = lists:foldl(
                                              fun maps:remove/2,
                                              Batches1, OrphanIds)}),
                    {ok, ParentLineage};
                {error, Reason, Ctx1} ->
                    put_context(Ctx1),
                    {error, Reason}
            end;
        {error, _} = Error -> Error
    end.

finish_preflight(Actor, Lineage, TxId, Ctx) ->
    case {invocation_authorized(Actor, Lineage, Ctx),
          maps:find(Lineage, Ctx#ctx.lineages),
          maps:find(TxId, Ctx#ctx.txs)} of
        {false, _, _} -> {error, not_allowed};
        {true, {ok, #lineage{tail = TxId, parent = Parent}},
         {ok, #tx{owner = Actor} = Tx}} ->
            case has_child_tx(TxId, Ctx#ctx.txs) of
                true -> {error, active_child_transaction};
                false -> {ok, Tx, Parent}
            end;
        {true, _, _} -> {error, transaction_scope_mismatch}
    end.

has_child_tx(TxId, Txs) ->
    lists:any(fun(#tx{parent = Parent}) -> Parent =:= TxId end,
              maps:values(Txs)).

detach_owner(_TxId, [], Batches, Orphans) -> {Batches, Orphans};
detach_owner(TxId, [BatchId | Rest], Batches0, Orphans0) ->
    case maps:find(BatchId, Batches0) of
        {ok, #batch{owners = Owners0} = Batch} ->
            Owners1 = maps:remove(TxId, Owners0),
            case map_size(Owners1) of
                0 -> detach_owner(TxId, Rest, Batches0,
                                  [{BatchId, Batch} | Orphans0]);
                _ -> detach_owner(TxId, Rest,
                                  Batches0#{BatchId => Batch#batch{owners = Owners1}},
                                  Orphans0)
            end;
        error ->
            detach_owner(TxId, Rest, Batches0, Orphans0)
    end.

batch_groups(BatchIds, Ctx) ->
    batch_groups_from_records(
      [{Id, maps:get(Id, Ctx#ctx.batches)} || Id <- BatchIds]).

batch_groups_from_records(Batches) ->
    lists:foldl(
      fun({BatchId, #batch{materialized = Materialized}}, Groups0) ->
          maps:fold(
            fun(ScopeId, true, Groups) ->
                maps:update_with(ScopeId, fun(Ids) -> [BatchId | Ids] end,
                                 [BatchId], Groups)
            end, Groups0, Materialized)
      end, #{}, Batches).

apply_groups(Operation, Groups, Ctx0) ->
    lists:foldl(
      fun({ScopeId, BatchIds0}, {ok, Ctx}) ->
          BatchIds = lists:sort(BatchIds0),
          case scope_for_id(ScopeId, Ctx) of
              {ok, Scope} ->
                  case scope_batch_call(Operation, Scope, BatchIds) of
                      {ok, Dirty, _Generation} ->
                          {ok, update_dirty(ScopeId, Dirty, Ctx)};
                      {error, Reason} -> {error, Reason, Ctx}
                  end;
              {error, Reason} -> {error, Reason, Ctx}
          end;
         (_Group, {error, _Reason, _Ctx} = Error) -> Error
      end, {ok, Ctx0}, lists:sort(maps:to_list(Groups))).

scope_batch_call(restore, Scope, BatchIds) ->
    quod_scope_session:restore_many(Scope, BatchIds);
scope_batch_call(release, Scope, BatchIds) ->
    quod_scope_session:release_many(Scope, BatchIds).

update_dirty(ScopeId, Dirty, Ctx) ->
    Ctx#ctx{dirty = (Ctx#ctx.dirty)#{ScopeId => Dirty}}.

lineage_exists(none, _Ctx) -> true;
lineage_exists(Lineage, Ctx) -> maps:is_key(Lineage, Ctx#ctx.lineages).

invocation_authorized(Actor, Lineage, #ctx{invocations = Invocations} = Ctx) ->
    case lineage_exists(Lineage, Ctx) of
        false -> false;
        true ->
            case maps:find(Actor, Invocations) of
                {ok, Lineage} -> true;
                {ok, Base} -> descendant_owned(Actor, Lineage, Base, Ctx, 0);
                error -> false
            end
    end.

descendant_owned(_Actor, Base, Base, _Ctx, _Depth) -> true;
descendant_owned(_Actor, none, _Base, _Ctx, _Depth) -> false;
descendant_owned(Actor, Lineage, Base, Ctx, Depth)
  when Depth < ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF ->
    case maps:find(Lineage, Ctx#ctx.lineages) of
        {ok, #lineage{parent = Parent, tail = TxId}} ->
            case maps:find(TxId, Ctx#ctx.txs) of
                {ok, #tx{owner = Actor}} ->
                    descendant_owned(Actor, Parent, Base, Ctx, Depth + 1);
                _ -> false
            end;
        error -> false
    end;
descendant_owned(_Actor, _Lineage, _Base, _Ctx, _Depth) -> false.

lineage_tail_and_txs(none, _Ctx) -> {none, []};
lineage_tail_and_txs(Lineage, Ctx) ->
    #lineage{tail = Tail, tx_ids_rev = TxsRev} =
        maps:get(Lineage, Ctx#ctx.lineages),
    {Tail, TxsRev}.

lineage_tx_ids(none, _Ctx) -> [];
lineage_tx_ids(Lineage, Ctx) ->
    (maps:get(Lineage, Ctx#ctx.lineages))#lineage.tx_ids_rev.

lineage_tx_set(Lineage, Ctx) ->
    maps:from_keys(lineage_tx_ids(Lineage, Ctx), true).

owners_within(Owners, TxSet) ->
    lists:all(fun(TxId) -> maps:is_key(TxId, TxSet) end,
              maps:keys(Owners)).

bounded_unique_ids(Ids) -> bounded_unique_ids(Ids, #{}, 0).

bounded_unique_ids([], _Seen, Count) -> {ok, Count};
bounded_unique_ids(_Ids, _Seen,
                   ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF) ->
    {error, limit};
bounded_unique_ids([<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>> = Id | Rest],
                   Seen, Count) ->
    case maps:is_key(Id, Seen) of
        true -> {error, duplicate};
        false -> bounded_unique_ids(Rest, Seen#{Id => true}, Count + 1)
    end;
bounded_unique_ids([_Invalid | _], _Seen, _Count) -> {error, invalid};
bounded_unique_ids(_Improper, _Seen, _Count) -> {error, improper}.

new_id(Ctx) ->
    new_id(Ctx, []).

new_id(Ctx, Reserved) ->
    Id = crypto:strong_rand_bytes(?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8),
    case lists:member(Id, Reserved) orelse
         maps:is_key(Id, Ctx#ctx.txs) orelse
         maps:is_key(Id, Ctx#ctx.lineages) orelse
         maps:is_key(Id, Ctx#ctx.batches) of
        true -> new_id(Ctx, Reserved);
        false -> Id
    end.

new_proxy_id(Proxies) ->
    Id = crypto:strong_rand_bytes(?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8),
    case maps:is_key(Id, Proxies) of
        true -> new_proxy_id(Proxies);
        false -> Id
    end.

scope_for_id(ScopeId, #ctx{scope_ids = ScopeIds, scopes = Scopes}) ->
    case maps:find(ScopeId, ScopeIds) of
        {ok, Identity} ->
            case maps:find(Identity, Scopes) of
                {ok, #scope{handle = Scope}} -> {ok, Scope};
                error -> {error, {protocol_error, session_binding}}
            end;
        error -> {error, not_allowed}
    end.

registered_in(#ctx{scope_ids = ScopeIds}, ScopeId) ->
    maps:is_key(ScopeId, ScopeIds).

valid_actor({<<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>,
             <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>}) -> true;
valid_actor(_) -> false.

new_scope_id(#ctx{scope_ids = ScopeIds}) ->
    ScopeId = crypto:strong_rand_bytes(
                ?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS div 8),
    case maps:is_key(ScopeId, ScopeIds) of
        true -> new_scope_id(context());
        false -> ScopeId
    end.

context() ->
    case get(?KEY) of
        #ctx{} = Ctx -> Ctx;
        undefined -> erlang:error(no_proof_context)
    end.

put_context(#ctx{} = Ctx) -> _ = put(?KEY, Ctx), ok.
