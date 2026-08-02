-module(quod_ask).
-moduledoc """
The `::` **ask** operator — a goal in one ontology proved inside another
(`doc/inter-ontology.md`). This module implements both co-hosted and QUIC-backed asks.

- **Asking side** — `ask_2/3` is the erlog predicate registered on `{'::' ,2}`. It runs
  inside the asking proof's worker, enforces bounded depth and streams one solution per
  Prolog choice point. Recursive selection is ordinary Prolog recursion, including
  selecting an ontology already present in the semantic call chain.
- **Co-hosted target** — one origin proof owns one reusable target scope per pinned
  ontology. Repeated and re-entrant calls share its staged overlay while retaining
  independent bounded continuations.
- **Network target** — until the session wire slice replaces it, the current QUIC path
  uses the bounded demand-driven answer worker below. Reads are gated by `can_read` for
  the supplied chain and authenticated peer key.

Errors are surfaced as `throw({quod_ask_error, Reason})`, which `quod_prolog`'s proof
runner turns into `{error, Reason}` — the loud, distinct catalog of `doc/inter-ontology.md`
§8 (`unknown_ontology`, `unreachable`, `too_deep`, `not_allowed`, …), never
a silent failure.
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_transport_limits.hrl").
-include("quod_proof_limits.hrl").

-export([load/1, ask_2/3, follow_unique_2/3, follow_clear_2/3,
         start_answer/7, start_answer_remote/10,
         subscribe/1, ask_channel/1, decode_open/1, decode_next/1, decode_cancel/1,
         reject_remote/5, answer_channel/1, authorize_scope/5, close_stream/1]).
-ifdef(TEST).
-export([test_remote_answer/3, test_solution_disposition/2,
         test_serve_nested/1, test_await_scope_reply/2]).
-endif.

%% The ask-chain depth cap and the per-`next` no-progress budget (doc/inter-ontology.md §9).
-define(NEXT_TIMEOUT_MS, 30000).
-define(MAX_OPEN_RETRIES, 300).
-define(OPEN_RETRY_MS, 100).

-define(ASK_CHANNEL_TAG, quod_ask).
-define(ANSWER_CHANNEL_TAG, quod_ask_answer).
-define(MAX_ANSWER_CHANNEL_BYTES, 128).

-if(?ERLOG_MAX_FAILURE_REASONS_BYTES >= ?QUOD_TRANSPORT_MAX_FRAME_BYTES).
-error("failure reason stack must stay below the transport frame bound").
-endif.

-doc "Register the `::` handler onto a freshly-built kb (`#est{}`).".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est) ->
    Db1 = erlog_int:add_compiled_proc({'::', 2}, ?MODULE, ask_2, Db0),
    Db2 = erlog_int:add_compiled_proc({'$quod_follow_unique', 1},
                                      ?MODULE, follow_unique_2, Db1),
    Est#est{db = erlog_int:add_compiled_proc({'$quod_follow_clear', 0},
                                             ?MODULE, follow_clear_2, Db2)}.

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

%% All argument-position clauses in one relation call share Erlog's clause-choice
%% label. Keep only the first occurrence of an answer until the terminal clause
%% clears that label.
follow_unique_2(Goal, Next, #est{bs = Bs, cps = Cps} = St) ->
    {'$quod_follow_unique', Answer0} = erlog_int:dderef(Goal, Bs),
    Answer = erlog_int:dderef(Answer0, Bs),
    case follower_label(Cps) of
        undefined ->
            erlog_int:prove_body(Next, St);
        Label ->
            Key = {'$quod_follow_seen', Label},
            Seen = case get(Key) of undefined -> #{}; Value -> Value end,
            case maps:is_key(Answer, Seen) of
                true -> erlog_int:fail(St);
                false -> put(Key, Seen#{Answer => true}),
                         erlog_int:prove_body(Next, St)
            end
    end.

%% The synthetic cleanup clause runs after every real follower has exhausted.
%% A trailing fail-only clause keeps the relation choice point (and its label)
%% alive while this callback executes.
follow_clear_2(_Goal, _Next, #est{cps = Cps} = St) ->
    case follower_label(Cps) of
        undefined -> ok;
        Label -> _ = erase({'$quod_follow_seen', Label})
    end,
    erlog_int:fail(St).

follower_label([#cp{type = goal_clauses, label = Label} | _]) -> Label;
follower_label([_ | Rest]) -> follower_label(Rest);
follower_label([]) -> undefined.

do_ask(NsTerm, Inner, Next, St) ->
    Self = quod_predicates:ctx_ns(quod_predicates:context(St)),
    case quod_ontology_name:flatten(NsTerm) of
        error  -> ask_error({bad_name, NsTerm});
        Self   -> erlog_int:prove_body([Inner | Next], St);  %% self-ask: in place, no hop, no chain growth
        Target -> guarded_ask(Self, Target, Inner, Next, St)
    end.

guarded_ask(Self, Target, Inner, Next, St) ->
    quod_predicates:in_verdict(St) andalso ask_error(ask_in_membership_verdict),
    Chain = case quod_predicates:ctx_chain(quod_predicates:context(St)) of
                [] -> [Self];   %% no context (defensive): start the chain at this ontology
                C  -> C
            end,
    length(Chain) >= ?QUOD_MAX_ACTIVE_PROOF_DEPTH andalso
        ask_error({too_deep, Target}),
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
                error -> ask_error(broken_stream)
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

%% Variable names are implementation-local atoms. Normalize them before a remote
%% term crosses the node boundary so the safe decoder never needs to create an atom
%% merely because an asker called its variable `D` or `Result`.
wire_term(Term) ->
    {T, _Next, _Names} = wire_term(Term, 0, #{}),
    T.

wire_term({Name}, Next, Names) ->
    case maps:find(Name, Names) of
        {ok, Id} -> {{Id}, Next, Names};
        error    -> {{Next}, Next + 1, Names#{Name => Next}}
    end;
wire_term(Term, Next, Names) when is_tuple(Term) ->
    {Items, Next1, Names1} = wire_list(tuple_to_list(Term), Next, Names),
    {list_to_tuple(Items), Next1, Names1};
wire_term([H | T], Next, Names) ->
    {H1, Next1, Names1} = wire_term(H, Next, Names),
    {T1, Next2, Names2} = wire_term(T, Next1, Names1),
    {[H1 | T1], Next2, Names2};
wire_term([], Next, Names) -> {[], Next, Names};
wire_term(Term, Next, Names) -> {Term, Next, Names}.

wire_list([], Next, Names) -> {[], Next, Names};
wire_list([H | T], Next, Names) ->
    {H1, Next1, Names1} = wire_term(H, Next, Names),
    {T1, Next2, Names2} = wire_list(T, Next1, Names1),
    {[H1 | T1], Next2, Names2}.

-spec ask_error(term()) -> no_return().
ask_error(Reason) -> throw({quod_ask_error, Reason}).

%%%===================================================================
%%% ask selection — reusable co-hosted scopes and bounded transport invocations
%%%===================================================================

%% A shared proof session routes every co-hosted selection through its one
%% origin-owned scope map. Isolated policy/tests without a proof context and the
%% current QUIC transport use the bounded single-invocation path below.
open(_Self, Target, GoalTerm, Chain, St) ->
    St1 = publish_session(St),
    case session_metadata(St1) of
        {origin, {quod_proof_context, _ProofId, Origin}} when Origin =:= self() ->
            case origin_open(Target, GoalTerm, Chain, self()) of
                {ok, Stream} -> {ok, Stream, refresh_session(St1)};
                {error, _} = Error -> Error
            end;
        {scope, ProofId, Origin, _SessionRef, ScopePid}
          when ScopePid =:= self(), is_pid(Origin) ->
            case nested_open(Origin, ProofId, Target, GoalTerm, Chain) of
                {ok, Stream} -> {ok, Stream, refresh_session(St1)};
                {error, _} = Error -> Error
            end;
        _ ->
            case open_transport_invocation(Target, GoalTerm, Chain) of
                {ok, Stream} -> {ok, Stream, St1};
                {error, _} = Error -> Error
            end
    end.

%% Open one bounded transport invocation. The scope-session wire slice replaces
%% the remote half of this function before the distributed-proof feature gate.
open_transport_invocation(Target, GoalTerm, Chain) ->
    case quod_reg:where({quod_prolog, Target}) of
        undefined ->
            case quod_directory:resolve(Target) of
                unknown -> {error, {unknown_ontology, Target}};
                {known, []} -> {error, {unreachable, Target}};
                {known, Routes} ->
                    open_remote_routes(Target, GoalTerm, Chain, Routes)
            end;
        _Engine -> open_local(Target, GoalTerm, Chain, ?MAX_OPEN_RETRIES)
    end.

origin_open(Target, Goal, Chain, Owner) ->
    case origin_scope(Target) of
        {ok, Scope} ->
            case open_scope_invocation(Scope, Goal, Chain) of
                {ok, Invocation} ->
                    case quod_proof_context:new_proxy(Owner, Invocation) of
                        {ok, Ref} -> {ok, {origin_scope_stream, Ref, 1}};
                        {error, _} = Error ->
                            close_stream(Invocation),
                            Error
                    end;
                {error, _} = Error -> Error
            end;
        remote ->
            case open_transport_invocation(Target, Goal, Chain) of
                {ok, Stream} ->
                    case quod_proof_context:new_proxy(
                           Owner, {transport_invocation, Stream}) of
                        {ok, Ref} -> {ok, {origin_scope_stream, Ref, 1}};
                        {error, _} = Error ->
                            close_stream(Stream),
                            Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

origin_scope(Target) ->
    case quod_reg:where({quod_prolog, Target}) of
        undefined -> remote;
        _Engine ->
            case quod_simplex:genesis_hash(Target) of
                <<_:256>> = Anchor ->
                    Identity = {Target, Anchor},
                    quod_proof_context:get_or_open_scope(
                      Identity,
                      fun() -> open_shared_scope(Target, Anchor,
                                                 ?MAX_OPEN_RETRIES) end);
                undefined ->
                    {error, {unreachable, Target}}
            end
    end.

open_shared_scope(Target, Anchor, Retries) ->
    case quod_reg:where({quod_prolog, Target}) of
        undefined -> {error, {unreachable, Target}};
        Engine ->
            ProofId = quod_proof_context:proof_id(),
            ReadOnly = quod_proof_context:read_only(),
            try gen_server:call(
                  Engine, {scope_open, ProofId, Anchor, ReadOnly},
                  ?NEXT_TIMEOUT_MS) of
                {ok, Handle} ->
                    {ok, quod_scope_session:pid(Handle), Handle};
                {error, busy} when Retries > 0 ->
                    timer:sleep(?OPEN_RETRY_MS),
                    open_shared_scope(Target, Anchor, Retries - 1);
                {error, busy} -> {error, no_progress};
                {error, not_ready} -> {error, {unreachable, Target}};
                {error, Reason} -> {error, Reason}
            catch exit:_ -> {error, {unreachable, Target}}
            end
    end.

open_scope_invocation(
  {local_scope, Ns, _Anchor, Height, Session}, Goal, Chain) ->
    case authorize_scope(Goal, Chain, Ns, Height, Session) of
        false -> {error, not_allowed};
        true ->
            InvocationId = make_ref(),
            Context = quod_predicates:proof_context(
                        Ns, Height, undefined, [Ns | Chain]),
            case quod_proof_session:open(
                   Session, InvocationId, Goal, Context) of
                ok -> {ok, {local_scope_invocation, Session, InvocationId, 1}};
                {error, Reason} -> {error, Reason}
            end
    end;
open_scope_invocation(Handle, Goal, Chain) ->
    InvocationId = make_ref(),
    RequestRef = make_ref(),
    ok = quod_scope_session:open(
           Handle, RequestRef, InvocationId, Goal, Chain),
    case await_scope_reply(Handle, RequestRef) of
        {opened, InvocationId} ->
            {ok, {shared_scope_invocation, Handle, InvocationId, 1}};
        {error, Reason} ->
            quod_scope_session:cancel(Handle, InvocationId),
            {error, Reason};
        _ ->
            quod_scope_session:cancel(Handle, InvocationId),
            {error, broken_stream}
    end.

stream_next(Stream, St) ->
    St1 = publish_session(St),
    Result =
        case Stream of
            {origin_scope_stream, Ref, Expected} ->
                origin_advance(Ref, self(), Expected);
            {nested_scope_stream, Origin, ProofId, Ref, Expected} ->
                nested_advance(Origin, ProofId, Ref, Expected);
            _ ->
                next(Stream)
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

origin_advance(Ref, Owner, Expected) ->
    case quod_proof_context:proxy(Ref, Owner) of
        {ok, {shared_scope_invocation, Handle, InvocationId, Expected}} ->
            RequestRef = make_ref(),
            ok = quod_scope_session:next(
                   Handle, RequestRef, InvocationId, Expected),
            shared_advance_reply(
              Ref, Owner, Handle, InvocationId, Expected,
              await_scope_reply(Handle, RequestRef));
        {ok, {local_scope_invocation, Session, InvocationId, Expected}} ->
            local_advance_reply(
              Ref, Owner, Session, InvocationId, Expected,
              quod_proof_session:next(Session, InvocationId));
        {ok, {transport_invocation, Transport}} ->
            transport_advance_reply(Ref, Owner, next(Transport));
        {ok, _WrongSequence} ->
            {error, broken_stream};
        {error, _} ->
            {error, broken_stream}
    end.

shared_advance_reply(Ref, Owner, Handle, InvocationId, Expected,
                     {solution, Expected, Solution, Dirty}) ->
    Pid = quod_scope_session:pid(Handle),
    ok = quod_proof_context:mark_dirty(Pid, Dirty),
    Next = {shared_scope_invocation, Handle, InvocationId, Expected + 1},
    ok = quod_proof_context:update_proxy(Ref, Owner, Next),
    {solution, Solution, origin_stream(Ref, Expected + 1)};
shared_advance_reply(Ref, Owner, Handle, _InvocationId, Expected,
                     {complete, Expected, Reasons, Dirty}) ->
    ok = quod_proof_context:mark_dirty(
           quod_scope_session:pid(Handle), Dirty),
    ok = quod_proof_context:drop_proxy(Ref, Owner),
    {complete, Reasons};
shared_advance_reply(Ref, Owner, Handle, _InvocationId, _Expected,
                     {error, Reason, Dirty}) ->
    %% The error aborts this proof, but retaining the final dirty bit keeps the
    %% origin's scope accounting exact while cleanup runs.
    ok = quod_proof_context:mark_dirty(
           quod_scope_session:pid(Handle), Dirty),
    _ = quod_proof_context:drop_proxy(Ref, Owner),
    {error, Reason};
shared_advance_reply(Ref, Owner, Handle, InvocationId, _Expected,
                     {error, Reason}) ->
    quod_scope_session:cancel(Handle, InvocationId),
    _ = quod_proof_context:drop_proxy(Ref, Owner),
    {error, Reason};
shared_advance_reply(Ref, Owner, Handle, InvocationId, _Expected, _Reply) ->
    quod_scope_session:cancel(Handle, InvocationId),
    _ = quod_proof_context:drop_proxy(Ref, Owner),
    {error, broken_stream}.

local_advance_reply(Ref, Owner, Session, InvocationId, Expected,
                    {solution, Solution}) ->
    Next = {local_scope_invocation, Session, InvocationId, Expected + 1},
    ok = quod_proof_context:update_proxy(Ref, Owner, Next),
    {solution, Solution, origin_stream(Ref, Expected + 1)};
local_advance_reply(Ref, Owner, _Session, _InvocationId, _Expected,
                    {complete, Reasons}) ->
    ok = quod_proof_context:drop_proxy(Ref, Owner),
    {complete, Reasons};
local_advance_reply(Ref, Owner, _Session, _InvocationId, _Expected,
                    {error, Reason}) ->
    _ = quod_proof_context:drop_proxy(Ref, Owner),
    {error, Reason}.

transport_advance_reply(Ref, Owner, {solution, Solution, Transport1}) ->
    ok = quod_proof_context:update_proxy(
           Ref, Owner, {transport_invocation, Transport1}),
    {solution, Solution, origin_stream(Ref, undefined)};
transport_advance_reply(Ref, Owner, {complete, Reasons}) ->
    ok = quod_proof_context:drop_proxy(Ref, Owner),
    {complete, Reasons};
transport_advance_reply(Ref, Owner, {error, Reason}) ->
    _ = quod_proof_context:drop_proxy(Ref, Owner),
    {error, Reason}.

origin_stream(Ref, Expected) -> {origin_scope_stream, Ref, Expected}.

nested_open(Origin, ProofId, Target, Goal, Chain) ->
    RequestRef = make_ref(),
    Origin ! {proof_nested_open, ProofId, self(), RequestRef,
              Target, Goal, Chain},
    case await_nested_reply(Origin, ProofId, RequestRef) of
        {opened, Ref} ->
            {ok, {nested_scope_stream, Origin, ProofId, Ref, 1}};
        {error, Reason} ->
            {error, Reason};
        _ ->
            {error, broken_stream}
    end.

nested_advance(Origin, ProofId, Ref, Expected) ->
    RequestRef = make_ref(),
    Origin ! {proof_nested_next, ProofId, self(), RequestRef, Ref, Expected},
    case await_nested_reply(Origin, ProofId, RequestRef) of
        {solution, Expected, Solution} ->
            {solution, Solution,
             {nested_scope_stream, Origin, ProofId, Ref, Expected + 1}};
        {complete, Expected, Reasons} ->
            {complete, Reasons};
        {error, Reason} ->
            request_nested_cancel(Origin, ProofId, Ref),
            {error, Reason};
        _ ->
            request_nested_cancel(Origin, ProofId, Ref),
            {error, broken_stream}
    end.

await_nested_reply(Origin, ProofId, RequestRef) ->
    receive
        {proof_nested_reply, ProofId, RequestRef, Reply} ->
            Reply;
        Message = {scope_invoke_open, _, _, _, _, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef);
        Message = {scope_invoke_next, _, _, _, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef);
        Message = {scope_invoke_cancel, _, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef);
        Message = {scope_close, _, _, _} ->
            dispatch_reentrant(Message, Origin, ProofId, RequestRef)
    after ?NEXT_TIMEOUT_MS ->
        {error, no_progress}
    end.

dispatch_reentrant(Message, Origin, ProofId, RequestRef) ->
    case quod_scope_session:dispatch(Message) of
        stop -> {error, no_progress};
        _ -> await_nested_reply(Origin, ProofId, RequestRef)
    end.

await_scope_reply(Handle, RequestRef) ->
    Pid = quod_scope_session:pid(Handle),
    MRef = monitor(process, Pid),
    try await_scope_reply_loop(Handle, RequestRef, MRef)
    after demonitor(MRef, [flush])
    end.

await_scope_reply_loop(
  {quod_scope_session, Pid, ProofId, SessionRef, _Ns, _Anchor} = Handle,
  RequestRef, MRef) ->
    receive
        {scope_reply, Pid, ProofId, SessionRef, RequestRef, Reply} ->
            Reply;
        Message = {proof_nested_open, _, _, _, _, _, _} ->
            serve_nested(Message),
            await_scope_reply_loop(Handle, RequestRef, MRef);
        Message = {proof_nested_next, _, _, _, _, _} ->
            serve_nested(Message),
            await_scope_reply_loop(Handle, RequestRef, MRef);
        Message = {proof_nested_cancel, _, _, _} ->
            serve_nested(Message),
            await_scope_reply_loop(Handle, RequestRef, MRef);
        {'DOWN', MRef, process, Pid, _Reason} ->
            {error, broken_stream}
    after ?NEXT_TIMEOUT_MS ->
        {error, no_progress}
    end.

serve_nested({proof_nested_open, ProofId, From, RequestRef,
              Target, Goal, Chain}) ->
    Reply =
        case valid_nested_source(ProofId, From) of
            true ->
                case origin_open(Target, Goal, Chain, From) of
                    {ok, {origin_scope_stream, Ref, 1}} -> {opened, Ref};
                    {error, Reason} -> {error, Reason}
                end;
            false -> {error, not_allowed}
        end,
    From ! {proof_nested_reply, ProofId, RequestRef, Reply},
    ok;
serve_nested({proof_nested_next, ProofId, From, RequestRef, Ref, Expected}) ->
    Reply =
        case valid_nested_source(ProofId, From) of
            true -> nested_origin_reply(
                      Expected, origin_advance(Ref, From, Expected));
            false -> {error, not_allowed}
        end,
    From ! {proof_nested_reply, ProofId, RequestRef, Reply},
    ok;
serve_nested({proof_nested_cancel, ProofId, From, Ref}) ->
    case valid_nested_source(ProofId, From) of
        true ->
            case cancel_origin_proxy(Ref, From) of
                ok -> ok;
                {error, _Reason} -> ok
            end;
        false -> ok
    end.

nested_origin_reply(Expected, {solution, Solution, _Stream}) ->
    {solution, Expected, Solution};
nested_origin_reply(Expected, {complete, Reasons}) ->
    {complete, Expected, Reasons};
nested_origin_reply(_Expected, {error, Reason}) ->
    {error, Reason}.

valid_nested_source(ProofId, From) ->
    ProofId =:= quod_proof_context:proof_id() andalso
        quod_proof_context:registered_scope(From).

-ifdef(TEST).
test_serve_nested(Message) -> serve_nested(Message).
test_await_scope_reply(Handle, RequestRef) ->
    await_scope_reply(Handle, RequestRef).
-endif.

cancel_origin_proxy(Ref, Owner) ->
    case quod_proof_context:proxy(Ref, Owner) of
        {ok, Invocation} ->
            ok = close_stream(Invocation),
            ok = quod_proof_context:drop_proxy(Ref, Owner),
            ok;
        {error, Reason} -> {error, Reason}
    end.

request_nested_cancel(Origin, ProofId, Ref) ->
    Origin ! {proof_nested_cancel, ProofId, self(), Ref},
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

open_local(Target, GoalTerm, Chain, Retries) ->
    case quod_reg:where({quod_prolog, Target}) of
        undefined -> {error, {unknown_ontology, Target}};
        Engine ->
            try gen_server:call(Engine,
                                {ask_open, GoalTerm, Chain, self()}, ?NEXT_TIMEOUT_MS) of
                {ok, Pid}             -> {ok, new_stream(Engine, Pid)};
                {error, busy} when Retries > 0 ->
                    timer:sleep(?OPEN_RETRY_MS),
                    open_local(Target, GoalTerm, Chain, Retries - 1);
                {error, busy}         -> {error, no_progress};
                {error, not_ready}    -> {error, {unreachable, Target}};
                {error, R}            -> {error, R}
            catch exit:_ -> {error, {unreachable, Target}}
            end
    end.

open_remote_routes(Target, _GoalTerm, _Chain, []) ->
    {error, {unreachable, Target}};
open_remote_routes(Target, GoalTerm, Chain, [Route | Rest]) ->
    AskId = crypto:strong_rand_bytes(16),
    AskCh = ask_channel(Target),
    case open_route(Route, AskCh) of
        {ok, AskLink, ExpectedKey, Confirmation} ->
            open_remote_route(Target, GoalTerm, Chain, Rest, AskId, AskLink,
                              AskCh, ExpectedKey, Confirmation);
        {error, _} ->
            open_remote_routes(Target, GoalTerm, Chain, Rest)
    end.

open_remote_route(Target, GoalTerm, Chain, Rest, AskId, AskLink, AskCh,
                  ExpectedKey, Confirmation) ->
    case quod_ask_router:register(AskId, ExpectedKey) of
        {ok, AnswerCh} ->
            {ok, WireGoal} = quod_wire_term:encode(wire_term(GoalTerm)),
            Payload = term_to_binary(
                        {quod_ask_open, AskId, WireGoal, Chain, AnswerCh},
                        [deterministic]),
            %% Start the owner guard before the remote open.  If this proof dies
            %% at any point after registration, it cancels a target worker that
            %% may already have accepted the frame; an early cancel is harmless.
            Guard = watch_owner(self(), AskLink, AskId),
            case quod_link:send_reliable(
                   AskLink, Payload, ?NEXT_TIMEOUT_MS) of
                ok ->
                    {ok, {remote_stream, AskId, AskLink, AskCh, 1, Guard,
                          ExpectedKey, Confirmation}};
                {error, _} ->
                    stop_owner(Guard),
                    ok = quod_ask_router:unregister(AskId),
                    open_remote_routes(Target, GoalTerm, Chain, Rest)
            end;
        {error, unavailable} ->
            {error, no_progress}
    end.

open_route(#{scope := direct, status := provisional,
             namespace := Ns, endpoint := Endpoint}, Channel) ->
    case open_link_identified(Endpoint, Channel) of
        {ok, LinkPid, NodeKey} ->
            {ok, LinkPid, NodeKey, {confirm_direct, Ns, Endpoint, NodeKey}};
        {error, _} = Error ->
            Error
    end;
open_route(#{scope := direct, status := confirmed, node_key := NodeKey,
             endpoint := Endpoint}, Channel) ->
    open_link_pinned(NodeKey, Endpoint, Channel);
open_route(#{scope := system, node_key := NodeKey,
             endpoint := Endpoint}, Channel) ->
    open_link_pinned(NodeKey, Endpoint, Channel);
open_route(_Route, _Channel) ->
    {error, bad_route}.

open_link_pinned(NodeKey, Endpoint, Channel) ->
    Ref = quod_quic:open_link_pinned(NodeKey, Endpoint, Channel),
    receive
        {link_up, Ref, NodeKey, Channel, LinkPid} ->
            {ok, LinkPid, NodeKey, none};
        {link_error, Ref, NodeKey, Channel} ->
            {error, unreachable}
    after ?NEXT_TIMEOUT_MS -> {error, no_progress}
    end.

open_link_identified(Endpoint, Channel) ->
    Ref = quod_quic:open_link_identified(Endpoint, Channel),
    receive
        {link_up, Ref, NodeKey, Channel, LinkPid}
          when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
            {ok, LinkPid, NodeKey};
        {link_error, Ref, _Peer, Channel} ->
            {error, unreachable}
    after ?NEXT_TIMEOUT_MS -> {error, no_progress}
    end.

subscribe(Ns) -> quod_reg:subscribe({channel, ask_channel(Ns)}).

ask_channel(Ns) -> term_to_binary({?ASK_CHANNEL_TAG, Ns}, [deterministic]).
answer_channel(NodeKey) when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
    term_to_binary({?ANSWER_CHANNEL_TAG, NodeKey}, [deterministic]).

decode_open(Payload) when is_binary(Payload) ->
    try safe_binary_to_term(Payload) of
        {quod_ask_open, AskId, WireGoal, Chain, AnswerCh}
          when is_binary(AskId), byte_size(AskId) =:= 16,
               is_binary(AnswerCh), byte_size(AnswerCh) =< ?MAX_ANSWER_CHANNEL_BYTES,
               is_list(Chain) ->
            case {valid_chain(Chain),
                  quod_wire_term:decode_goal(WireGoal)} of
                {true, {ok, Goal}} -> {ok, AskId, Goal, Chain, AnswerCh};
                _ -> error
            end;
        _ -> error
    catch _:_ -> error
    end;
decode_open(_) -> error.

decode_next(Payload) when is_binary(Payload) ->
    try safe_binary_to_term(Payload) of
        {quod_ask_next, AskId} when is_binary(AskId), byte_size(AskId) =:= 16 ->
            {ok, AskId};
        _ -> error
    catch _:_ -> error
    end;
decode_next(_) -> error.

decode_cancel(Payload) when is_binary(Payload) ->
    try safe_binary_to_term(Payload) of
        {quod_ask_cancel, AskId} when is_binary(AskId), byte_size(AskId) =:= 16 ->
            {ok, AskId};
        _ -> error
    catch _:_ -> error
    end;
decode_cancel(_) -> error.

new_stream(Engine, Pid) -> {ask_stream, Engine, Pid, monitor(process, Pid), 1}.

next({ask_stream, _Engine, Pid, MRef, Expected} = Stream) ->
    Pid ! {next, self()},
    receive
        {ask_solution, Pid, Expected, Sol} ->
            {ask_stream, Engine, Pid, MRef, _} = Stream,
            {solution, Sol, {ask_stream, Engine, Pid, MRef, Expected + 1}};
        {ask_solution, Pid, _Wrong, _Sol} ->
            close_stream(Stream),
            {error, broken_stream};
        {ask_complete, Pid, Expected, Reasons} ->
            demonitor(MRef, [flush]),
            case checked_completion(Reasons) of
                {complete, _} = Complete -> Complete;
                error -> {error, broken_stream}
            end;
        {ask_complete, Pid, _Wrong, _Reasons} ->
            close_stream(Stream),
            {error, broken_stream};
        {ask_error, Pid, R} ->
            demonitor(MRef, [flush]),
            {error, R};
        {'DOWN', MRef, process, Pid, _Reason} ->
            {error, broken_stream}
    after ?NEXT_TIMEOUT_MS ->
        close_stream(Stream),
        {error, no_progress}
    end;

next(Stream = {remote_stream, AskId, AskLink, AskCh, Expected, Guard,
               ExpectedKey, Confirmation}) ->
    NextPayload = term_to_binary({quod_ask_next, AskId}),
    case quod_link:send_reliable(AskLink, NextPayload, ?NEXT_TIMEOUT_MS) of
        ok ->
            receive
                {quod_ask_answer, AskId, Reply} ->
                    case remote_answer(Reply, AskId, Expected) of
                        {solution, Sol} ->
                            confirm_route(Confirmation),
                            {solution, Sol,
                             {remote_stream, AskId, AskLink, AskCh,
                              Expected + 1, Guard, ExpectedKey, none}};
                        {complete, Reasons} ->
                            confirm_route(Confirmation),
                            close_stream(Stream), {complete, Reasons};
                        {error, Reason} ->
                            confirm_route(Confirmation),
                            close_stream(Stream), {error, Reason};
                        error -> close_stream(Stream), {error, broken_stream}
                    end;
                {quod_ask_stream_down, AskId} ->
                    close_stream(Stream), {error, broken_stream}
            after ?NEXT_TIMEOUT_MS ->
                close_stream(Stream), {error, no_progress}
            end;
        {error, _} ->
            close_stream(Stream),
            {error, broken_stream}
    end.

remote_answer(Reply, AskId, Expected) ->
    try case Reply of
        {quod_ask_answer, AskId, Expected, {solution, WireSol}} ->
            case quod_wire_term:decode(WireSol) of
                {ok, Sol} -> {solution, Sol};
                _ -> error
            end;
        {quod_ask_answer, AskId, Expected, {complete, WireReasons}} ->
            case quod_wire_term:decode(WireReasons) of
                {ok, Reasons} -> checked_completion(Reasons);
                _ -> error
            end;
        {quod_ask_answer, AskId, error, WireReason} ->
            case quod_wire_term:decode(WireReason) of
                {ok, Reason} -> decode_remote_error(Reason);
                _ -> error
            end;
        _ -> error
    end
    catch _:_ -> error
    end.

-ifdef(TEST).
test_remote_answer(Reply, AskId, Expected) ->
    remote_answer(Reply, AskId, Expected).
-endif.

checked_completion(Reasons) ->
    case erlog_int:merge_failure_reasons(Reasons, #est{}) of
        {ok, _} -> {complete, Reasons};
        error -> error
    end.

safe_binary_to_term(Payload) ->
    case quod_safe_term:decode(Payload, ?QUOD_TRANSPORT_MAX_FRAME_BYTES) of
        {ok, Term} -> Term;
        {error, Reason} -> error(Reason)
    end.

decode_remote_error(Reason) ->
    case allowed_remote_error(Reason) of
        true -> {error, Reason};
        false -> error
    end.

allowed_remote_error(Reason) ->
    lists:member(Reason, [rebuilding, busy, not_allowed,
                          too_many_answers, answer_too_big,
                          foreign_write_unsupported, no_progress,
                          prove_failed, broken_stream,
                          ask_in_membership_verdict]) orelse
    case Reason of
        {Tag, _Detail} -> lists:member(Tag, [unknown_ontology, unreachable,
                                             too_deep, bad_name,
                                             erlog]);
        _ -> false
    end.

encode_error(AskId, Reason) ->
    SafeReason = case allowed_remote_error(Reason) of true -> Reason; false -> prove_failed end,
    WireReason = case quod_wire_term:encode(SafeReason) of
                     {ok, Wire} -> Wire;
                     {error, bad_term} ->
                         {ok, Fallback} = quod_wire_term:encode(prove_failed),
                         Fallback
                 end,
    term_to_binary({quod_ask_answer, AskId, error, WireReason}, [deterministic]).

valid_chain([_|_] = Chain)
  when length(Chain) =< ?QUOD_MAX_ACTIVE_PROOF_DEPTH ->
    lists:all(fun is_binary/1, Chain);
valid_chain(_) -> false.

close_stream({shared_scope_invocation, Handle, InvocationId, _Seq}) ->
    quod_scope_session:cancel(Handle, InvocationId);
close_stream({local_scope_invocation, Session, InvocationId, _Seq}) ->
    quod_proof_session:cancel(Session, InvocationId);
close_stream({transport_invocation, Stream}) ->
    close_stream(Stream);
close_stream({origin_scope_stream, Ref, _Expected}) ->
    _ = try cancel_origin_proxy(Ref, self()) catch _:_ -> ok end,
    ok;
close_stream({nested_scope_stream, Origin, ProofId, Ref, _Expected}) ->
    request_nested_cancel(Origin, ProofId, Ref);
close_stream({ask_stream, Engine, Pid, MRef, _}) ->
    gen_server:cast(Engine, {ask_cancel, Pid}),
    demonitor(MRef, [flush]),
    ok;
close_stream({remote_stream, AskId, AskLink, _AskCh, _Expected, Guard,
              _ExpectedKey, _Confirmation}) ->
    %% Both control and answer links are shared. Cancellation is per ask id;
    %% never close a shared stream merely because one proof finishes.
    _ = quod_link:send_reliable(
          AskLink, term_to_binary({quod_ask_cancel, AskId}), 1000),
    stop_owner(Guard),
    ok = quod_ask_router:unregister(AskId),
    ok.

watch_owner(Owner, AskLink, AskId) ->
    spawn(fun() ->
        Ref = monitor(process, Owner),
        receive
            stop -> demonitor(Ref, [flush]), ok;
            {'DOWN', Ref, process, Owner, _Reason} ->
                _ = quod_link:send_reliable(
                      AskLink, term_to_binary({quod_ask_cancel, AskId}), 1000),
                ok
        end
    end).

stop_owner(Pid) -> Pid ! stop, ok.

%%%===================================================================
%%% answering side — the demand-driven solution worker
%%%===================================================================

%% Spawned by the target quod_prolog on {ask_open}. Holds a shared-store snapshot
%% handle and streams solutions of Goal, one per {next,_}, dying with the asker.
-spec start_answer(binary(), tuple(), non_neg_integer(), term(), [binary()], pid(), pid()) -> pid().
start_answer(Ns, Est, Height, Goal, Chain, Asker, Engine) ->
    %% The engine monitors this pid. It must not be linked: an answer worker may
    %% legitimately die with an untrusted transport peer, and that failure must stop
    %% at the worker boundary.
    spawn(fun() ->
        _ = quod_process:kill_when_owner_dies(Engine, self()),
        try answer_init(Ns, Est, Height, Goal, Chain, Asker, Engine)
        catch
            Class:Reason:Stack ->
                logger:warning("quod_ask[~p]: answer worker crashed: ~p:~p ~p",
                               [Ns, Class, Reason, Stack]),
                Asker ! {ask_error, self(), prove_failed}
        end
    end).

%% Remote target-side answer worker. The request link is monitored by quod_prolog;
%% reply links are multiplexed per asking node and owned by the transport, so this
%% worker never closes one when its individual ask ends.
start_answer_remote(Ns, Est, Height, Goal, Chain, AskId,
                    Peer, PeerEndpoint, AnswerCh, Engine) ->
    spawn(fun() ->
        _ = quod_process:kill_when_owner_dies(Engine, self()),
        case open_link_pinned(Peer, PeerEndpoint, AnswerCh) of
            {ok, Link, Peer, none} ->
                Asker = {remote, AskId, Link},
                try answer_init(Ns, Est, Height, Goal, Chain,
                                [Peer | Chain], Asker, Engine)
                catch
                    Class:Reason:Stack ->
                        logger:warning(
                          "quod_ask[~p]: remote answer worker crashed: ~p:~p ~p",
                          [Ns, Class, Reason, Stack]),
                        _ = sink_send(Asker, {error, prove_failed}),
                        sink_close(Asker)
                end;
            {error, _} -> ok
        end
    end).

reject_remote(Peer, PeerEndpoint, AnswerCh, AskId, Reason) ->
    %% Rejections stay bounded under an open-frame flood: no helper process is
    %% spawned, and the transport owns the shared answer link.
    quod_quic:send_pinned(
      Peer, PeerEndpoint, AnswerCh, encode_error(AskId, Reason)).

confirm_route({confirm_direct, Ns, Endpoint, NodeKey}) ->
    _ = quod_directory:confirm_direct_seed(Ns, Endpoint, NodeKey),
    ok;
confirm_route(none) ->
    ok.

answer_init(Ns, Est, Height, Goal, Chain, Asker, Engine) ->
    answer_init(Ns, Est, Height, Goal, Chain, Chain, Asker, Engine).

answer_init(Ns, Est, Height, Goal, Chain, AuthorizedSubjects, Asker, Engine) ->
    %% Run the served ask under a proof execution context (`m:quod_predicates`): this ontology, the
    %% frozen height, and the ask chain with this ontology PREPENDED (added only for nested asks;
    %% permission checks the incoming chain, not the target itself).
    Ctx = quod_predicates:proof_context(Ns, Height, undefined, [Ns | Chain]),
    W = quod_erlog_db_local_prove:wrap_state(
          quod_predicates:set_context(Est, Ctx), #{read_set => false}),
    case can_read_subjects(Goal, AuthorizedSubjects, Ns, W) of
        false ->
            _ = sink_send(Asker, {error, not_allowed}),
            sink_close(Asker);
        true  -> answer_loop(
                   quod_proof_scope:open_wrapped(Goal, W),
                   Asker, 0, 1, Engine)
    end.

answer_loop(State, Asker, Count, Seq, Engine) ->
    receive
        {next, Asker} ->
            Engine ! {ask_step_started, self()},
            answer_once(State, Asker, Count, Seq, Engine);
        {next, AskId} when is_binary(AskId) ->
            case Asker of
                {remote, AskId, _Link} ->
                    answer_once(State, Asker, Count, Seq, Engine);
                _ ->
                    answer_loop(State, Asker, Count, Seq, Engine)
            end;
        {stop, Asker} -> close_answer(State, Asker)
    after ?NEXT_TIMEOUT_MS ->
        close_answer(State, Asker)    %% asker went silent (its monitor also covers death)
    end.

answer_once(State, Asker, Count, Seq, Engine) ->
    case quod_proof_scope:next(State) of
        {solution, Sol, State1} ->
            case solution_disposition(State1, Count) of
                send ->
                    case sink_solution(Asker, Seq, Sol) of
                        ok ->
                            Engine ! {ask_step_finished, self()},
                            answer_loop(
                              State1, Asker, Count + 1, Seq + 1, Engine);
                        too_big ->
                            _ = sink_send(Asker, {error, answer_too_big}),
                            close_answer(State1, Asker);
                        send_failed ->
                            close_answer(State1, Asker)
                    end;
                {error, Reason} ->
                    _ = sink_send(Asker, {error, Reason}),
                    close_answer(State1, Asker)
            end;
        {complete, Reasons, State1} ->
            _ = sink_send(Asker, {complete, Seq, Reasons}),
            close_answer(State1, Asker);
        {error, R, State1, _RevisionPolicy} ->
            _ = sink_send(Asker, {error, R}),
            close_answer(State1, Asker)
    end.

solution_disposition(State, Count) ->
    case quod_proof_scope:local_changes(State) of
        [] when Count < ?QUOD_MAX_ANSWERS_PER_INVOCATION -> send;
        [] -> {error, too_many_answers};
        _ -> {error, foreign_write_unsupported}
    end.

-ifdef(TEST).
test_solution_disposition(State, at_limit) ->
    solution_disposition(State, ?QUOD_MAX_ANSWERS_PER_INVOCATION);
test_solution_disposition(State, Count) ->
    solution_disposition(State, Count).
-endif.

sink_solution(Asker, Seq, Sol) ->
    case quod_wire_term:encode(Sol) of
        {ok, WireSol} ->
            case Asker of
                Pid when is_pid(Pid) ->
                    case erlang:external_size(WireSol) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES of
                        true -> Pid ! {ask_solution, self(), Seq, Sol}, ok;
                        false -> too_big
                    end;
                {remote, AskId, Link} ->
                    Payload = term_to_binary(
                                {quod_ask_answer, AskId, Seq, {solution, WireSol}},
                                [deterministic]),
                    case byte_size(Payload) =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES of
                        true ->
                            case quod_link:send_reliable(
                                   Link, Payload, ?NEXT_TIMEOUT_MS) of
                                ok -> ok;
                                {error, _} -> send_failed
                            end;
                        false -> too_big
                    end
            end;
        {error, bad_term} -> too_big
    end.

sink_send(Asker, {complete, Seq, Reasons}) when is_pid(Asker) ->
    _ = Asker ! {ask_complete, self(), Seq, Reasons}, ok;
sink_send({remote, AskId, Link}, {complete, Seq, Reasons}) ->
    WireReasons = completion_wire(Reasons),
    reliable_sink_send(
      Link, term_to_binary(
              {quod_ask_answer, AskId, Seq, {complete, WireReasons}},
              [deterministic]));
sink_send(Asker, {error, Reason}) when is_pid(Asker) ->
    _ = Asker ! {ask_error, self(), Reason}, ok;
sink_send({remote, AskId, Link}, {error, Reason}) ->
    reliable_sink_send(Link, encode_error(AskId, Reason)).

completion_wire(Reasons) ->
    case quod_wire_term:encode(Reasons) of
        {ok, WireReasons} -> WireReasons;
        %% Erlog's byte bounds are independent of the transport's structural
        %% depth bound. Preserve logical failure and report bounded diagnostic
        %% truncation if an otherwise-valid local reason cannot cross the wire.
        {error, bad_term} ->
            {ok, Truncated} = quod_wire_term:encode([fail_reasons_truncated]),
            Truncated
    end.

reliable_sink_send(Link, Payload) ->
    case quod_link:send_reliable(Link, Payload, ?NEXT_TIMEOUT_MS) of
        ok -> ok;
        {error, _} -> send_failed
    end.

sink_close({remote, _AskId, _Link}) -> ok;
sink_close(_LocalAsker) -> ok.

close_answer(State, Asker) ->
    quod_proof_scope:close(State),
    sink_close(Asker).

%% Every declared ontology on the path and the authenticated remote peer must be
%% authorized. This prevents a peer laundering access through an invented chain.
%% Policies are proved against this ontology's committed KB.
can_read_subjects(Goal, Subjects, Ns, W) ->
    lists:all(fun(Subject) -> prove_bool({can_read, Goal, Subject, Ns}, W) end, Subjects).

-doc "Apply the existing committed-view admission rule before a shared scope invocation.".
-spec authorize_scope(term(), [binary()], binary(), non_neg_integer(),
                      quod_proof_session:session()) -> boolean().
authorize_scope(Goal, Subjects, Ns, Height, Session)
  when is_list(Subjects), is_binary(Ns), is_integer(Height), Height >= 0 ->
    Ctx = quod_predicates:proof_context(
            Ns, Height, undefined, [Ns | Subjects]),
    Committed = quod_predicates:set_context(
                  quod_proof_session:committed_state(Session), Ctx),
    Wrapped = quod_erlog_db_local_prove:wrap_state(
                Committed, #{read_set => false}),
    try can_read_subjects(Goal, Subjects, Ns, Wrapped)
    after quod_erlog_db_local_prove:cleanup_read_set(Wrapped)
    end.

prove_bool(Goal, W) ->
    try erlog_int:prove_goal(Goal, W) of
        {succeed, _} -> true;
        _            -> false
    catch _:_ -> false end.
