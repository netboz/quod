-module(quod_ask).
-moduledoc """
The `::` **ask** operator — a goal in one ontology proved inside another
(`doc/inter-ontology.md`). This module implements both co-hosted and QUIC-backed asks.

- **Asking side** — `ask_2/3` is the erlog predicate registered on `{'::' ,2}`. It runs
  inside the asking proof's worker process. It resolves the target namespace, guards the
  ask (no circles, bounded depth, never during a membership vote), then STREAMS the
  target's solutions into the local proof one at a time through an erlog compiled choice
  point: the first solution unifies and continues; backtracking pulls the next.
- **Answering side** — the target's `m:quod_prolog` spawns an `answer` worker (via
  `start_answer/7`) holding the target's committed `#est{}` as a frozen view. It proves
  the goal there, demand-driven: one solution per `{next,_}` request, so a slow consumer
  never makes it buffer. The target engine monitors the asker and can kill this worker
  even during an unbounded derivation. Reads are gated by `can_read` for every ontology
  in the supplied chain and, remotely, for the authenticated peer key; completion is a
  minimal sequenced marker.

Errors are surfaced as `throw({quod_ask_error, Reason})`, which `quod_prolog`'s proof
runner turns into `{error, Reason}` — the loud, distinct catalog of `doc/inter-ontology.md`
§8 (`unknown_ontology`, `unreachable`, `circular_ask`, `too_deep`, `not_allowed`, …), never
a silent failure.
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_transport_limits.hrl").

-export([load/1, ask_2/3, follow_unique_2/3, follow_clear_2/3,
         start_answer/7, start_answer_remote/10,
         subscribe/1, ask_channel/1, decode_open/1, decode_next/1, decode_cancel/1,
         reject_remote/5, answer_channel/1]).

%% The ask-chain depth cap and the per-`next` no-progress budget (doc/inter-ontology.md §9).
-define(MAX_CHAIN, 8).
-define(NEXT_TIMEOUT_MS, 30000).
-define(MAX_ANSWERS, 10000).
-define(MAX_OPEN_RETRIES, 300).
-define(OPEN_RETRY_MS, 100).

-define(ASK_CHANNEL_TAG, quod_ask).
-define(ANSWER_CHANNEL_TAG, quod_ask_answer).
-define(MAX_ANSWER_CHANNEL_BYTES, 128).

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
%% asking proof's worker (see quod_prolog:proof_worker/8).
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
    lists:member(Target, Chain) andalso ask_error({circular_ask, Target}),
    length(Chain) >= ?MAX_CHAIN andalso ask_error({too_deep, Target}),
    InnerTerm = erlog_int:dderef(Inner, St#est.bs),
    case open(Self, Target, InnerTerm, Chain) of
        {ok, Stream} -> drive_stream(Stream, InnerTerm, Target, Next, St);
        {error, R}   -> ask_error(R)
    end.

%% Pull the next solution and either emit it (with a choice point for the one after) or,
%% when the target is exhausted, fail back into the surrounding proof.
drive_stream(Stream, GoalTerm, Target, Next, St) ->
    case next(Stream) of
        {solution, Sol, Stream1} ->
            emit(Stream1, GoalTerm, Target, Sol, Next, St);
        complete -> erlog_int:fail(St);
        {error, R} -> ask_error(R)
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
            erlog_int:prove_body(Next, St#est{bs = Bs1, vn = Vn1, cps = [Cp | St#est.cps]});
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
%%% co-hosted transport (asking-worker <-> answer-worker)
%%%===================================================================

%% Ask the target's engine to open a solution stream. A non-local target is
%% resolved through the live directory below. Runs in the asking worker.
open(_Self, Target, GoalTerm, Chain) ->
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
        {ask_complete, Pid, Expected} ->
            demonitor(MRef, [flush]),
            complete;
        {ask_complete, Pid, _Wrong} ->
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
                        complete ->
                            confirm_route(Confirmation),
                            close_stream(Stream), complete;
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
        {quod_ask_answer, AskId, Expected, complete} -> complete;
        {quod_ask_answer, AskId, error, WireReason} ->
            case quod_wire_term:decode(WireReason) of
                {ok, Reason} -> decode_remote_error(Reason);
                _ -> error
            end;
        _ -> error
    end
    catch _:_ -> error
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
                                             circular_ask, too_deep, bad_name,
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

valid_chain([_|_] = Chain) when length(Chain) =< ?MAX_CHAIN ->
    lists:all(fun is_binary/1, Chain);
valid_chain(_) -> false.

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
        true  -> answer_loop({fresh, Goal, W}, Asker, 0, 1, Engine)
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
        {stop, Asker} -> sink_close(Asker)
    after ?NEXT_TIMEOUT_MS -> sink_close(Asker)    %% asker went silent (its monitor also covers death)
    end.

answer_once(State, Asker, Count, Seq, Engine) ->
    case step(State) of
        {solution, Sol, State1} when Count < ?MAX_ANSWERS ->
            case sink_solution(Asker, Seq, Sol) of
                ok ->
                    Engine ! {ask_step_finished, self()},
                    answer_loop(State1, Asker, Count + 1, Seq + 1, Engine);
                too_big ->
                    _ = sink_send(Asker, {error, answer_too_big}),
                    sink_close(Asker);
                send_failed ->
                    sink_close(Asker)
            end;
        {solution, _Sol, _State1} ->
            _ = sink_send(Asker, {error, too_many_answers}),
            sink_close(Asker);
        done ->
            _ = sink_send(Asker, {complete, Seq}),
            sink_close(Asker);
        {error, R} ->
            _ = sink_send(Asker, {error, R}),
            sink_close(Asker)
    end.

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

sink_send(Asker, {complete, Seq}) when is_pid(Asker) ->
    _ = Asker ! {ask_complete, self(), Seq}, ok;
sink_send({remote, AskId, Link}, {complete, Seq}) ->
    reliable_sink_send(
      Link, term_to_binary({quod_ask_answer, AskId, Seq, complete},
                           [deterministic]));
sink_send(Asker, {error, Reason}) when is_pid(Asker) ->
    _ = Asker ! {ask_error, self(), Reason}, ok;
sink_send({remote, AskId, Link}, {error, Reason}) ->
    reliable_sink_send(Link, encode_error(AskId, Reason)).

reliable_sink_send(Link, Payload) ->
    case quod_link:send_reliable(Link, Payload, ?NEXT_TIMEOUT_MS) of
        ok -> ok;
        {error, _} -> send_failed
    end.

sink_close({remote, _AskId, _Link}) -> ok;
sink_close(_LocalAsker) -> ok.

step({fresh, Goal, W}) -> drive(Goal, catch erlog_int:prove_goal(Goal, W));
step({more, Goal, St}) -> drive(Goal, catch erlog_int:fail(St)).

drive(Goal, {succeed, St}) ->
    case quod_erlog_db_local_prove:get_local_changes((St#est.db)#db.ref) of
        [] -> {solution, erlog_int:dderef(Goal, St#est.bs), {more, Goal, St}};
        _  -> {error, foreign_write_unsupported}
    end;
drive(_Goal, {fail, _})            -> done;
drive(_Goal, {quod_ask_error, R})  -> {error, R};   %% a nested `::` inside Goal raised it
drive(_Goal, {erlog_error, E, _})  -> {error, {erlog, E}};
drive(_Goal, {erlog_error, E})     -> {error, {erlog, E}};
drive(_Goal, _Other)               -> {error, prove_failed}.

%% Every declared ontology on the path and the authenticated remote peer must be
%% authorized. This prevents a peer laundering access through an invented chain.
%% Policies are proved against this ontology's committed KB.
can_read_subjects(Goal, Subjects, Ns, W) ->
    lists:all(fun(Subject) -> prove_bool({can_read, Goal, Subject, Ns}, W) end, Subjects).

prove_bool(Goal, W) ->
    try erlog_int:prove_goal(Goal, W) of
        {succeed, _} -> true;
        _            -> false
    catch _:_ -> false end.
