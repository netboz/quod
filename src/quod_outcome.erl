-module(quod_outcome).
-moduledoc """
Rebuildable transaction and distributed-group outcome index for one ontology.

The namespace's `m:quod_prolog` process owns this library state. A production
namespace stores a compact classification index in DETS beside its rebuildable
ledger projection;
isolated tests may explicitly select the in-memory backend. The consensus
ledger remains authoritative: live apply and replay call the same `terminal/4`
function, and contradictory terminal data fails instead of being overwritten.

The canonical transaction id binds the target identity and complete semantic
write. The index therefore never duplicates the bounded goal, result, diff, or
read set: a row keeps only the id, plan digest, anchored reference and status.
Its recorded terminal slot lets
the state projection rebuild that exact ledger occurrence after restart while
skipping later duplicate occurrences of the same semantic transaction.
Terminal writes from one committed block are staged and flushed in one DETS
insert by `flush/1`; pending admission remains immediately durable. Only the
4,096 most recently used compact rows are retained in memory; all
other lookups go to the disk index.

Distributed state uses the same file and owner.  One fixed state row holds the
journal-derived local pending-Begin identity, the ledger-active dual-role
projection, and the ordered applied floor.  Exact per-GroupId rows remain on
disk after their small in-memory cache entries are evicted, so an old direct
abort tombstone can never become absence.  A committed block's transaction,
group, state, and floor updates are staged and synced together by `flush/1`.
When a new Prolog owner opens an existing file, it preserves ordinary outcome
rows but clears this rebuildable DTX subset and resets its floor before the
owner is exposed.  The mandatory slot-1 ledger replay then reconstructs both D
and the DTX projection through the same reducer effects used live; retaining a
terminal history would incorrectly turn that replay into effect-free duplicates.
""".

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([open/3, close/1,
         admit/2, discard_unsubmitted/2,
         classify/2, terminal/4, flush/1,
         check_operation/3, claim_operation/4,
         ref_identity/1, lookup_ref/2, lookup_live/3, public/1,
         project_pending_begin/2, dtx_state/1,
         lookup_group/2, group_history/2,
         apply_dtx/6, advance_applied/2, applied_floor/1]).

-export_type([index/0, outcome/0]).

-define(FORMAT, 5).
-define(CACHE_LIMIT, 4096).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

-record(index, {
          ns :: binary(),
          anchor :: binary(),
          backend :: {dets, term()} | {memory, map()},
          cache = #{} :: map(),
          order = gb_trees:empty() :: gb_trees:tree(),
          clock = 0 :: non_neg_integer(),
          staged = #{} :: map(),
          dtx :: map(),
          %% Only a successful flush advances public visibility.  The staged
          %% state may already contain a higher floor while a block is being
          %% applied, but callers must not observe a terminal Complete yet.
          applied_floor = 0 :: non_neg_integer()
         }).

-opaque index() :: #index{}.
-type outcome() ::
        #{ref := {transaction, binary(), binary(), binary()},
          tx_id := binary(), plan_digest := binary(),
          status := pending | {committed, pos_integer()} |
                    {rejected, atom(), pos_integer()}} |
        #{type := group,
          ref := {group, binary(), <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>},
          status := term()} |
        #{type := operation,
          ref := {operation, binary(), <<_:256>>, <<_:256>>, <<_:256>>},
          request_digest := <<_:256>>,
          outcome_ref := term(), first_slot := pos_integer()}.
-type pending_begin() ::
        #{lane := {<<_:256>>, <<_:256>>}, sequence := pos_integer(),
          group_id := <<_:256>>}.
-type index_error() :: outcome_index_bad_transaction |
                       outcome_index_bad_group |
                       outcome_index_bad_operation |
                       outcome_index_gap |
                       outcome_index_conflict |
                       {outcome_index_io, term()}.
-type deferred_finalize_ack() ::
        {finalize_applied, <<_:256>>, pos_integer(), non_neg_integer()}.

-doc "Return the immutable ontology identity carried by any public outcome reference.".
-spec ref_identity(term()) -> {ok, {binary(), <<_:256>>}} | error.
ref_identity({transaction, Ns, <<_:256>> = Anchor, <<_:256>>})
  when is_binary(Ns), byte_size(Ns) > 0 ->
    {ok, {Ns, Anchor}};
ref_identity(
  {group, Ns, <<_:256>> = Anchor, <<_:256>>, <<_:256>>, <<_:256>>})
  when is_binary(Ns), byte_size(Ns) > 0 ->
    {ok, {Ns, Anchor}};
ref_identity(
  {operation, Ns, <<_:256>> = Anchor, <<_:256>>, <<_:256>>})
  when is_binary(Ns), byte_size(Ns) > 0 ->
    {ok, {Ns, Anchor}};
ref_identity(_) ->
    error.

-doc "Open the compact outcome index for one exact ontology founding.".
-spec open(binary(), binary(), map()) -> {ok, index()} | {error, term()}.
open(Ns, <<_:256>> = Anchor, Config) when is_binary(Ns), is_map(Config) ->
    case maps:get(outcome_backend, Config, disk) of
        disk ->
            %% This projection is rebuilt from the ledger, so it belongs on
            %% the same fast, replaceable volume rather than the slow identity
            %% and vote-journal volume.
            open_disk(Ns, Anchor, quod_ledger_store:ledger_dir(Config));
        memory ->
            Dtx = initial_dtx_state(Ns, Anchor),
            {ok, #index{ns = Ns, anchor = Anchor,
                        backend = {memory, #{}}, dtx = Dtx}}
    end;
open(_Ns, _Anchor, _Config) ->
    {error, outcome_index_bad_anchor}.

open_disk(Ns, Anchor, DataDir) ->
    Dir = quod_ledger_store:ns_dir(DataDir, Ns),
    ok = filelib:ensure_path(Dir),
    Path = filename:join(Dir, "outcomes.dets"),
    open_disk_file(Ns, Anchor, Path, true).

open_disk_file(Ns, Anchor, Path, MayReset) ->
    %% DETS names may be terms. Using the path directly avoids minting one
    %% permanent VM atom for every ontology.
    Name = Path,
    case dets:open_file(
           Name, [{file, Path}, {type, set}, {keypos, 1}, {repair, false}]) of
        {ok, Name} ->
            inspect_open_table(Ns, Anchor, Name, Path, MayReset);
        {error, {needs_repair, _}} when MayReset ->
            %% This table is a derived index, never the source of truth. An
            %% unclean VM stop may leave DETS needing a full repair scan; reset
            %% it instead and let the authoritative ledger replay rebuild it.
            case file:delete(Path) of
                ok -> open_disk_file(Ns, Anchor, Path, false);
                {error, enoent} -> open_disk_file(Ns, Anchor, Path, false);
                {error, Reason} -> {error, {outcome_index_reset, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

inspect_open_table(Ns, Anchor, Name, Path, MayReset) ->
    try dets:lookup(Name, meta) of
        [] ->
            Dtx = initial_dtx_state(Ns, Anchor),
            case dets_write(
                   Name, [{meta, ?FORMAT, Anchor},
                          {state_key(Anchor), Dtx}]) of
                ok -> {ok, disk_index(Ns, Anchor, Name, Dtx)};
                {error, Reason} -> reset_open_table(
                                     Ns, Anchor, Name, Path, MayReset, Reason)
            end;
        [{meta, ?FORMAT, Anchor}] ->
            open_existing_state(Ns, Anchor, Name, Path, MayReset);
        Other ->
            %% This is a derived hard-break index. Old or malformed formats
            %% are discarded and reconstructed by authoritative ledger replay.
            reset_open_table(Ns, Anchor, Name, Path, MayReset,
                             {format, Other})
    catch
        Class:Reason ->
            reset_open_table(Ns, Anchor, Name, Path, MayReset,
                             {Class, Reason})
    end.

open_existing_state(Ns, Anchor, Name, Path, MayReset) ->
    Key = state_key(Anchor),
    case dets:lookup(Name, Key) of
        [{Key, Dtx}] ->
            case valid_dtx_state(Dtx, {Ns, Anchor}) of
                true ->
                    reset_existing_dtx(Ns, Anchor, Name);
                false ->
                    reset_open_table(
                      Ns, Anchor, Name, Path, MayReset, corrupt_state)
            end;
        Other ->
            reset_open_table(
              Ns, Anchor, Name, Path, MayReset, {state, Other})
    end.

%% The ontology database is rebuilt from slot 1 whenever its owner restarts.
%% Its DTX fold must therefore restart from the same empty prefix: retaining a
%% terminal group history would classify replayed controls as duplicates and
%% suppress the prepared Finalize effect that reconstructs D.  Ordinary
%% transaction rows are different: their terminal slot lets the existing
%% replay path re-apply exactly that occurrence, so preserve them.
reset_existing_dtx(Ns, Anchor, Name) ->
    Dtx = initial_dtx_state(Ns, Anchor),
    GroupRows = [{{{group, Anchor, '$1'}, '_'}, [], [true]}],
    try dets:select_delete(Name, GroupRows) of
        Count when is_integer(Count), Count >= 0 ->
            case dets_write(Name, {state_key(Anchor), Dtx}) of
                ok -> {ok, disk_index(Ns, Anchor, Name, Dtx)};
                {error, Reason} -> fail_existing_open(Name, Reason)
            end;
        Other ->
            fail_existing_open(Name, {dtx_reset, Other})
    catch
        Class:Reason ->
            fail_existing_open(Name, {dtx_reset, {Class, Reason}})
    end.

fail_existing_open(Name, Reason) ->
    _ = dets:close(Name),
    {error, {outcome_index_io, Reason}}.

disk_index(Ns, Anchor, Name, Dtx) ->
    disk_index(Ns, Anchor, Name, Dtx, 0).

disk_index(Ns, Anchor, Name, Dtx, Floor) ->
    #index{ns = Ns, anchor = Anchor, backend = {dets, Name},
           dtx = Dtx, applied_floor = Floor}.

initial_dtx_state(Ns, Anchor) ->
    #{pending_begin => none,
      projection => quod_dtx:initial_projection({Ns, Anchor}, 0),
      applied_floor => 0}.

reset_open_table(Ns, Anchor, Name, Path, true, _Reason) ->
    _ = dets:close(Name),
    case file:delete(Path) of
        ok -> open_disk_file(Ns, Anchor, Path, false);
        {error, enoent} -> open_disk_file(Ns, Anchor, Path, false);
        {error, DeleteReason} ->
            {error, {outcome_index_reset, DeleteReason}}
    end;
reset_open_table(_Ns, _Anchor, Name, _Path, false, Reason) ->
    _ = dets:close(Name),
    {error, {outcome_index_io, Reason}}.

-doc "Flush staged terminal rows and close the index.".
-spec close(index()) -> ok.
close(Index = #index{backend = {dets, Name}}) ->
    report_close_error(Name, flush, flush(Index)),
    report_close_error(Name, close, dets:close(Name)),
    ok;
close(#index{backend = {memory, _}}) -> ok.

report_close_error(_Name, _Operation, {ok, _Index}) -> ok;
report_close_error(_Name, _Operation, ok) -> ok;
report_close_error(Name, Operation, {error, Reason}) ->
    logger:error(
      "outcome index ~p failed to ~p during shutdown: ~0p",
      [Name, Operation, Reason]).

%% ===================================================================
%% Distributed-group projection
%% ===================================================================

-doc "Replace the rebuildable local pending-Begin identity from the journal.".
-spec project_pending_begin(index(), none | pending_begin()) ->
          {ok, index()} | {error, index_error()}.
project_pending_begin(Index = #index{dtx = #{pending_begin := none}}, none) ->
    {ok, Index};
project_pending_begin(Index = #index{dtx = Dtx}, none) ->
    {ok, stage_dtx_state(Index, Dtx#{pending_begin := none})};
project_pending_begin(Index = #index{dtx = Dtx}, Pending0) ->
    case normalize_pending_begin(Pending0) of
        {ok, Pending = #{lane := PendingLane,
                         group_id := PendingGroupId,
                         sequence := PendingSequence}} ->
            case maps:get(pending_begin, Dtx) of
                none ->
                    {ok, stage_dtx_state(
                           Index, Dtx#{pending_begin := Pending})};
                Pending ->
                    {ok, Index};
                #{lane := Lane, group_id := GroupId,
                  sequence := PreviousSequence}
                  when Lane =:= PendingLane,
                       GroupId =:= PendingGroupId,
                       PreviousSequence < PendingSequence ->
                    %% The signing journal may re-envelope one still-pending
                    %% semantic Begin after its admission-scoped lane advances.
                    %% Replace only that exact lane/group at a strictly newer
                    %% sequence; an older or differently-bound row remains a
                    %% fail-closed conflict.
                    {ok, stage_dtx_state(
                           Index, Dtx#{pending_begin := Pending})};
                _Other ->
                    {error, outcome_index_conflict}
            end;
        error ->
            {error, outcome_index_bad_group}
    end.

normalize_pending_begin(
  #{lane := {<<_:256>> = Admission, <<_:256>> = Author},
    sequence := Sequence, group_id := <<_:256>> = GroupId})
  when is_integer(Sequence), Sequence > 0, Sequence =< ?MAX_UINT64 ->
    {ok, #{lane => {Admission, Author}, sequence => Sequence,
           group_id => GroupId}};
normalize_pending_begin(_) ->
    error.

-doc "Current fixed-size DTX projection, including staged owner-local updates.".
-spec dtx_state(index()) -> map().
dtx_state(#index{dtx = Dtx}) -> Dtx.

-doc "Highest committed slot durably published by the outcome index.".
-spec applied_floor(index()) -> non_neg_integer().
applied_floor(#index{applied_floor = Floor}) -> Floor.

-doc "Stage the next ordered applied slot; replay at or below the floor is inert.".
-spec advance_applied(index(), non_neg_integer()) ->
          {ok, index()} | {error, index_error()}.
advance_applied(Index = #index{dtx = Dtx}, Slot)
  when is_integer(Slot), Slot >= 0, Slot =< ?MAX_UINT64 ->
    Floor = maps:get(applied_floor, Dtx),
    case Slot of
        _ when Slot =< Floor ->
            {ok, Index};
        _ when Slot =:= Floor + 1 ->
            {ok, stage_dtx_state(
                   Index, Dtx#{applied_floor := Slot})};
        _ ->
            {error, outcome_index_gap}
    end;
advance_applied(_Index, _Slot) ->
    {error, outcome_index_gap}.

stage_dtx_state(Index = #index{anchor = Anchor, staged = Staged}, Dtx) ->
    Index#index{dtx = Dtx,
                staged = Staged#{state_key(Anchor) => Dtx}}.

-doc "Look up one exact durable GroupId row.".
-spec lookup_group(index(), <<_:256>>) ->
          {{ok, map()} | not_found | {error, index_error()}, index()}.
lookup_group(Index, <<_:256>> = GroupId) ->
    Key = group_key(Index, GroupId),
    case cache_get(Key, Index) of
        {{ok, Row}, Index1} ->
            {{ok, Row}, Index1};
        {not_found, Index1} ->
            case backend_lookup(Index1, Key) of
                {ok, Row} -> {{ok, Row}, cache_put(Key, Row, Index1)};
                not_found -> {not_found, Index1};
                {error, Reason} -> {{error, Reason}, Index1}
            end
    end;
lookup_group(Index, _GroupId) ->
    {{error, outcome_index_bad_group}, Index}.

-doc "Return exact reducer history, with an empty history for an unseen group.".
-spec group_history(index(), <<_:256>>) ->
          {quod_dtx:group_history(), index()} | {error, index_error()}.
group_history(Index, <<_:256>> = GroupId) ->
    case lookup_group(Index, GroupId) of
        {{ok, #{history := History}}, Index1} -> {History, Index1};
        {not_found, Index1} -> {quod_dtx:initial_group_history(), Index1};
        {{error, Reason}, _Index1} -> {error, Reason}
    end;
group_history(_Index, _GroupId) ->
    {error, outcome_index_bad_group}.

-doc """
Stage one already-reduced committed DTX control.

`History`, `Projection`, and `Effects` must be the exact output of
`quod_dtx:reduce/4`.  For a prepared Finalize the caller applies or discards
the hidden plan before calling this function.  A returned `finalize_applied`
value is only a deferred acknowledgement token: buffer it with the block's
other post-apply work and do not send it to Simplex until the common
`advance_applied/2` -> `flush/1` -> MVCC publication sequence has succeeded.
No row becomes publicly terminal before that same boundary.
""".
-spec apply_dtx(index(), pos_integer(), quod_dtx:control(),
                quod_dtx:group_history(), quod_dtx:projection(), list()) ->
          {ok, index(), none | deferred_finalize_ack()} |
          {error, index_error()}.
apply_dtx(Index, Slot, Control, History, Projection, Effects)
  when is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64, is_list(Effects) ->
    try dtx_update(Index, Slot, Control, History, Projection, Effects)
    catch
        error:_ -> {error, outcome_index_bad_group}
    end;
apply_dtx(_Index, _Slot, _Control, _History, _Projection, _Effects) ->
    {error, outcome_index_bad_group}.

dtx_update(Index = #index{ns = Ns, anchor = Anchor}, Slot,
           Control, History, Projection, Effects) ->
    Target = quod_dtx:control_target(Control),
    Kind = quod_dtx:control_kind(Control),
    GroupId = quod_dtx:group_id(Control),
    Digest = quod_dtx:record_digest(Control),
    Checks = {Target =:= {Ns, Anchor},
              valid_history(History, GroupId),
              valid_projection(Projection, {Ns, Anchor})},
    case Checks of
        {true, true, true} ->
            dtx_update_known(
              Index, Slot, Control, Kind, GroupId, Digest,
              History, Projection, Effects);
        _ ->
            {error, outcome_index_bad_group}
    end.

dtx_update_known(Index, Slot, Control, Kind, GroupId, Digest,
                 History, Projection, Effects) ->
    case lookup_group(Index, GroupId) of
        {{ok, OldRow}, Index1} ->
            update_group_row(
              Index1, Slot, Control, Kind, GroupId, Digest,
              History, Projection, Effects, OldRow);
        {not_found, Index1} ->
            update_group_row(
              Index1, Slot, Control, Kind, GroupId, Digest,
              History, Projection, Effects, empty_group_row(GroupId));
        {{error, Reason}, _Index1} ->
            {error, Reason}
    end.

update_group_row(Index, Slot, Control, Kind, GroupId, Digest,
                 History, Projection, Effects, OldRow) ->
    OldHistory = maps:get(history, OldRow),
    Records = maps:get(records, History),
    ExistingRecords = maps:get(records, OldHistory),
    case history_extends(ExistingRecords, Records) andalso
         current_record_matches(Kind, Digest, Slot, Records,
                                ExistingRecords) of
        false ->
            {error, outcome_index_conflict};
        true ->
            Row0 = OldRow#{history := History},
            case capture_control(Control, Kind, GroupId, History, Row0) of
                {ok, Row1} ->
                    OldProjection = maps:get(
                                      projection,
                                      (Index#index.dtx)),
                    case apply_group_effects(
                           Effects, Kind, GroupId, History, Row1,
                           Projection, OldProjection,
                           maps:is_key(Kind, ExistingRecords)) of
                        {ok, Row2, DeferredAck, Projection1} ->
                            finish_group_update(
                              Index, GroupId, Row2, Projection,
                              Projection1, DeferredAck);
                        error ->
                            {error, outcome_index_conflict}
                    end;
                error ->
                    {error, outcome_index_conflict}
            end
    end.

finish_group_update(Index = #index{dtx = Dtx}, GroupId, Row,
                    Projection, ProjectionOverride, DeferredAck) ->
    StoredProjection = case ProjectionOverride of
                           none -> Projection;
                           _ -> ProjectionOverride
                       end,
    Pending0 = maps:get(pending_begin, Dtx),
    Pending = case Pending0 of
                  #{group_id := GroupId} -> none;
                  _ -> Pending0
              end,
    Dtx1 = Dtx#{pending_begin := Pending,
                projection := StoredProjection},
    Key = group_key(Index, GroupId),
    Index1 = stage_row(Key, Row, stage_dtx_state(Index, Dtx1)),
    {ok, cache_put(Key, Row, Index1), DeferredAck}.

stage_row(Key, Row, Index = #index{staged = Staged}) ->
    Index#index{staged = Staged#{Key => Row}}.

empty_group_row(GroupId) ->
    #{history => #{group_id => GroupId, records => #{}},
      ref => none, result => none,
      applied => none, terminal => none}.

history_extends(Old, New) ->
    maps:fold(
      fun(Kind, Entry, Acc) ->
              Acc andalso maps:get(Kind, New, different) =:= Entry
      end, true, Old).

current_record_matches(Kind, Digest, Slot, Records, Existing) ->
    case maps:find(Kind, Records) of
        {ok, #{digest := Digest, ref := Ref}} ->
            case maps:is_key(Kind, Existing) of
                true -> true;
                false -> ref_slot(Ref) =:= Slot
            end;
        _ -> false
    end.

capture_control(Control, 'begin', GroupId, _History, Row) ->
    case quod_dtx:control_body(Control) of
        {quod_dtx_begin, 2,
         {quod_dtx_manifest, 2, _ProofId,
          {OriginNs, OriginAnchor, <<_:256>> = Coordinator,
           <<_:256>> = Admission},
          _Nonce, _Principal, _Goal, _GoalDigest,
          Result, _ResultDigest, _RequestBinding, _Participants},
         _RequestAuth, _Authorization, _Bundles}
          when is_binary(OriginNs), OriginNs =/= <<>>,
               is_binary(OriginAnchor), byte_size(OriginAnchor) =:= 32,
               is_binary(Result) ->
            Ref = {group, OriginNs, OriginAnchor, Coordinator,
                   Admission, GroupId},
            set_once(ref, Ref,
              set_once_result(Result, Row));
        _ ->
            error
    end;
capture_control(Control, decision, _GroupId, History, Row) ->
    case history_record(decision, History) =:= quod_dtx:control_body(Control) of
        true -> {ok, Row};
        false -> error
    end;
capture_control(Control, complete, _GroupId, History, Row) ->
    CompleteRef = history_ref(complete, History),
    case quod_dtx:control_body(Control) of
        {quod_dtx_complete, 2, _, DecisionRef, FinalizeRows} ->
            capture_terminal(
              CompleteRef, DecisionRef, FinalizeRows, History, Row);
        _ ->
            error
    end;
capture_control(_Control, _Kind, _GroupId, _History, Row) ->
    {ok, Row}.

set_once_result(Result, #{result := none} = Row) ->
    case quod_durable_term:decode_result(Result) of
        {ok, _} -> {ok, Row#{result := Result}};
        {error, _} -> error
    end;
set_once_result(Result, #{result := Result} = Row) ->
    {ok, Row};
set_once_result(_Result, _Row) ->
    error.

set_once(_Key, _Value, error) -> error;
set_once(Key, Value, {ok, Row}) -> set_once(Key, Value, Row);
set_once(Key, Value, Row) ->
    case maps:get(Key, Row) of
        none -> {ok, Row#{Key := Value}};
        Value -> {ok, Row};
        _ -> error
    end.

capture_terminal(CompleteRef, DecisionRef, FinalizeRows, History, Row) ->
    case {history_record(decision, History),
          DecisionRef =:= history_ref(decision, History),
          participant_slots(FinalizeRows), maps:get(result, Row)} of
        {{quod_dtx_decision, 2, _, _, commit, _, none}, true,
         {ok, Slots}, Result} when is_binary(Result) ->
            Terminal = #{verdict => commit, complete_ref => CompleteRef,
                         slot => ref_slot(CompleteRef),
                         participant_slots => Slots},
            set_once(terminal, Terminal, Row);
        {{quod_dtx_decision, 2, _, _, abort, _, _} = Decision, true,
         {ok, Slots}, _Result} ->
            case quod_dtx:decision_failure_reasons(Decision) of
                {ok, [_ | _]} ->
                    Terminal =
                        #{verdict => abort, complete_ref => CompleteRef,
                          slot => ref_slot(CompleteRef),
                          participant_slots => Slots},
                    set_once(terminal, Terminal, Row);
                _ -> error
            end;
        _ ->
            error
    end.

participant_slots(Rows) ->
    participant_slots(Rows, none, 0, []).

participant_slots([], _Previous, Count, Acc) when Count >= 2 ->
    {ok, lists:reverse(Acc)};
participant_slots([{Identity, Ref, Generation} | Rest], Previous, Count, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       (Previous =:= none orelse Previous < Identity),
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    case valid_identity(Identity) andalso quod_dtx:validate_certified_ref(Ref) andalso
         certified_ref_identity(Ref) =:= Identity of
        true ->
            participant_slots(
              Rest, Identity, Count + 1,
              [{Identity, ref_slot(Ref), Generation} | Acc]);
        false -> error
    end;
participant_slots(_, _, _, _) ->
    error.

apply_group_effects([], _Kind, _GroupId, _History, Row,
                    _Projection, _OldProjection, true) ->
    {ok, Row, none, none};
apply_group_effects([Effect], Kind, GroupId, History, Row,
                    Projection, OldProjection, false) ->
    apply_group_effect(
      Effect, Kind, GroupId, History, Row, Projection, OldProjection);
apply_group_effects(_, _, _, _, _, _, _, _) ->
    error.

apply_group_effect({origin_started, GroupId, Ref}, 'begin', GroupId,
                   History, Row, _Projection, _OldProjection) ->
    exact_effect_ref('begin', Ref, History, Row);
apply_group_effect(
  {prepared, GroupId, Ref, Manifest, PlanDigest, PlanBlob, Generation},
                   prepare, GroupId, History, Row, Projection,
                   _OldProjection) ->
    case exact_history_ref(prepare, Ref, History) andalso
         is_binary(PlanBlob) andalso
         byte_size(PlanBlob) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES andalso
         is_integer(Generation) andalso Generation >= 0 andalso
         Generation =< ?MAX_UINT64 andalso
         projection_holds_plan(
           Projection, GroupId, Ref, Manifest, PlanDigest, PlanBlob,
           Generation) of
        true ->
            {ok, Row, none, none};
        false -> error
    end;
apply_group_effect({decided, GroupId, Verdict, Ref}, decision, GroupId,
                   History, Row, _Projection, _OldProjection)
  when Verdict =:= commit; Verdict =:= abort ->
    case exact_history_ref(decision, Ref, History) andalso
         decision_matches_effect(
           Verdict, Ref, history_record(decision, History)) of
        true -> {ok, Row, none, none};
        false -> error
    end;
apply_group_effect(
  {apply_prepared, GroupId, Manifest, PlanDigest, PlanBlob, Ref, Generation},
                   finalize, GroupId, History, Row, Projection,
                   OldProjection) ->
    applied_prepared(
      commit, Manifest, PlanDigest, PlanBlob, Ref, Generation, GroupId,
      History, Row, Projection, OldProjection);
apply_group_effect(
  {discard_prepared, GroupId, Manifest, PlanDigest, PlanBlob, Ref, Generation},
                   finalize, GroupId, History, Row, Projection,
                   OldProjection) ->
    applied_prepared(
      abort, Manifest, PlanDigest, PlanBlob, Ref, Generation, GroupId,
      History, Row, Projection, OldProjection);
apply_group_effect({direct_applied_abort, GroupId, Ref, Generation},
                   finalize, GroupId, History, Row,
                   _Projection, _OldProjection) ->
    case exact_history_ref(finalize, Ref, History) of
        true ->
            set_applied(abort, Ref, Generation, Row, none, GroupId);
        false -> error
    end;
apply_group_effect({completed, GroupId, commit, Ref}, complete, GroupId,
                   History, #{terminal := #{verdict := commit}} = Row,
                   _Projection, _OldProjection) ->
    exact_effect_ref(complete, Ref, History, Row);
apply_group_effect({completed, GroupId, abort, Ref, Reasons}, complete,
                   GroupId, History,
                   #{terminal := #{verdict := abort}} = Row,
                   _Projection, _OldProjection) ->
    case exact_history_ref(complete, Ref, History) andalso
         quod_dtx:decision_failure_reasons(
           history_record(decision, History)) =:= {ok, Reasons} of
        true -> {ok, Row, none, none};
        false -> error
    end;
apply_group_effect(_, _, _, _, _, _, _) ->
    error.

exact_effect_ref(Kind, Ref, History, Row) ->
    case exact_history_ref(Kind, Ref, History) of
        true -> {ok, Row, none, none};
        false -> error
    end.

decision_matches_effect(
  commit, _Ref, {quod_dtx_decision, 2, _, _, commit, _, none}) -> true;
decision_matches_effect(
  abort, _Ref, {quod_dtx_decision, 2, _, _, abort, _, _}) -> true;
decision_matches_effect(_, _, _) -> false.

applied_prepared(Verdict, Manifest, PlanDigest, PlanBlob, Ref, Generation,
                 GroupId, History, Row, Projection, OldProjection) ->
    case exact_history_ref(finalize, Ref, History) andalso
         old_projection_holds_plan(
           OldProjection, GroupId, Manifest, PlanDigest, PlanBlob) of
        true ->
            Slot = ref_slot(Ref),
            case quod_dtx:acknowledge_finalize(
                   GroupId, Slot, Generation, Projection) of
                {ok, Projection1} ->
                    set_applied(
                      Verdict, Ref, Generation,
                      Row, Projection1, GroupId);
                {error, _} -> error
            end;
        false -> error
    end.
projection_holds_plan(
  #{active :=
      #{group_id := GroupId,
        participant :=
          #{prepare_ref := StoredRef, manifest := Manifest,
            plan_digest := PlanDigest, plan := PlanBlob}},
    generation := StoredGeneration},
  GroupId, Ref, Manifest, PlanDigest, PlanBlob, Generation) ->
    Ref =:= StoredRef andalso Generation =:= StoredGeneration;
projection_holds_plan(_, _, _, _, _, _, _) -> false.

old_projection_holds_plan(
  #{active := #{group_id := GroupId,
                participant :=
                  #{manifest := Manifest, plan_digest := PlanDigest,
                    plan := PlanBlob}}},
  GroupId, Manifest, PlanDigest, PlanBlob) -> true;
old_projection_holds_plan(_, _, _, _, _) -> false.

set_applied(Verdict, Ref, Generation, Row, Projection, GroupId) ->
    Applied = #{verdict => Verdict, finalize_ref => Ref,
                slot => ref_slot(Ref), generation => Generation},
    case set_once(applied, Applied, Row) of
        {ok, Row1} ->
            case Projection of
                none ->
                    {ok, Row1, none, none};
                _ ->
                    DeferredAck = {finalize_applied, GroupId,
                                   ref_slot(Ref), Generation},
                    {ok, Row1, DeferredAck, Projection}
            end;
        error -> error
    end.

-doc "Admit one semantic submission, persisting a new pending row exactly once.".
-spec admit(index(), #transaction{}) ->
          {new | pending, index()} |
          {{terminal, outcome()}, index()} |
          {error, index_error()}.
admit(Index, #transaction{} = Transaction) ->
    case candidate(Index, Transaction) of
        {ok, Outcome = #{tx_id := TxId}} ->
            admit_candidate(Index, Transaction, TxId, Outcome);
        {error, _} = Error -> Error
    end.

admit_candidate(Index, Transaction, TxId, Outcome) ->
    TxKey = tx_key(Index, TxId),
    case lookup_tx(Index, TxId) of
        {not_found, Index1} ->
            case backend_put(Index1, TxKey, Outcome) of
                {ok, Index2} -> {new, Index2};
                {error, _} = Error -> Error
            end;
        {{ok, Existing}, Index1} ->
            case same_transaction(Existing, Transaction) of
                false -> {error, outcome_index_conflict};
                true ->
                    case maps:get(status, Existing) of
                        pending -> {pending, Index1};
                        _ -> {{terminal, Existing}, Index1}
                    end
            end;
        {{error, Reason}, _Index1} ->
            {error, Reason}
    end.

-doc "Remove a pending row only when the transaction was definitely not submitted.".
-spec discard_unsubmitted(index(), binary()) ->
          {ok, index()} | {error, index_error()}.
discard_unsubmitted(Index, <<_:256>> = TxId) ->
    TxKey = tx_key(Index, TxId),
    case backend_lookup(Index, TxKey) of
        {ok, #{status := pending}} -> backend_delete(Index, TxKey);
        {ok, _Terminal} -> {ok, Index};
        not_found -> {ok, Index};
        {error, _} = Error -> Error
    end.

valid_transaction_id(#index{ns = Ns, anchor = Anchor}, Transaction) ->
    quod_transaction:valid_id({Ns, Anchor}, Transaction).

-doc "Classify a committed transaction against the compact durable index.".
-spec classify(index(), #transaction{}) ->
          {new | pending | terminal, outcome(), index()} |
          {error, index_error()}.
classify(Index, #transaction{tx_id = <<_:256>> = TxId,
                             plan_digest = <<_:256>>} = T) ->
    case candidate(Index, T) of
        {ok, Candidate} ->
            classify_known_id(Index, TxId, T, Candidate);
        {error, _} = Error ->
            Error
    end;
classify(_Index, _Transaction) ->
    {error, outcome_index_bad_transaction}.

classify_known_id(Index, TxId, T, Candidate) ->
    case lookup_tx(Index, TxId) of
        {not_found, Index1} ->
            {new, Candidate, Index1};
        {{ok, Existing}, Index1} ->
            case same_transaction(Existing, T) of
                false -> {error, outcome_index_conflict};
                true ->
                    case maps:get(status, Existing) of
                        pending -> {pending, Existing, Index1};
                        _ -> {terminal, Existing, Index1}
                    end
            end;
        {{error, Reason}, _Index1} ->
            {error, Reason}
    end.

-doc "Stage one terminal classification from the caller's preceding classify/2 result.".
-spec terminal(index(), pos_integer(), committed | {rejected, atom()},
               {new | pending | terminal, outcome()}) ->
          {new | duplicate, outcome(), index()} | {error, index_error()}.
terminal(Index, Slot, Verdict, {Prior, Base})
  when is_integer(Slot), Slot > 0 ->
    Outcome = Base#{status => terminal_status(Verdict, Slot)},
    store_terminal(Index, Outcome, {Prior, Base});
terminal(_Index, _Slot, _Verdict, _Classification) ->
    {error, outcome_index_conflict}.

terminal_status(committed, Slot) -> {committed, Slot};
terminal_status({rejected, Reason}, Slot) -> {rejected, Reason, Slot}.

store_terminal(Index, Outcome = #{tx_id := TxId}, {Prior, _Base})
  when Prior =:= new; Prior =:= pending ->
    TxKey = tx_key(Index, TxId),
    Index1 = stage_terminal(Index, TxKey, Outcome),
    {new, Outcome, cache_put(TxKey, Outcome, Index1)};
store_terminal(Index, Outcome, {terminal, Existing}) ->
    case Existing =:= Outcome of
        true ->
            TxKey = tx_key(Index, maps:get(tx_id, Existing)),
            {duplicate, Existing, cache_put(TxKey, Existing, Index)};
        false -> {error, outcome_index_conflict}
    end;
store_terminal(_Index, _Outcome, _Prior) ->
    {error, outcome_index_conflict}.

candidate(Index = #index{ns = Ns, anchor = Anchor},
          #transaction{tx_id = TxId, plan_digest = PlanDigest} = T)
  when is_binary(TxId), is_binary(PlanDigest), byte_size(PlanDigest) =:= 32,
       byte_size(TxId) =:= 32 ->
    case valid_transaction_id(Index, T) of
        false ->
            {error, outcome_index_bad_transaction};
        true ->
            {ok, #{ref => {transaction, Ns, Anchor, TxId},
                   tx_id => TxId, plan_digest => PlanDigest,
                   status => pending}}
    end;
candidate(_Index, _Transaction) ->
    {error, outcome_index_bad_transaction}.

same_transaction(#{tx_id := TxId, plan_digest := Digest},
                 #transaction{tx_id = TxId, plan_digest = Digest}) ->
    true;
same_transaction(_Outcome, _Transaction) -> false.

-doc "Classify one signed operation claim against the authoritative origin index.".
-spec check_operation(index(), map(), term()) ->
          {new, index()} | {{claimed, map()}, index()} |
          {error, index_error()}.
check_operation(Index, Claim, OutcomeRef) ->
    case operation_candidate(Index, Claim, OutcomeRef, 1) of
        {ok, Key, _Row} ->
            case lookup_operation(Index, Key) of
                {not_found, Index1} -> {new, Index1};
                {{ok, Existing}, Index1} -> {{claimed, Existing}, Index1};
                {{error, Reason}, _Index1} -> {error, Reason}
            end;
        error ->
            {error, outcome_index_bad_operation}
    end.

-doc "Stage the first certified claim, or recognize replay of that exact slot.".
-spec claim_operation(index(), pos_integer(), map(), term()) ->
          {new | replay, index()} | {error, index_error()}.
claim_operation(Index, Slot, Claim, OutcomeRef)
  when is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64 ->
    case operation_candidate(Index, Claim, OutcomeRef, Slot) of
        {ok, Key, Row} ->
            case lookup_operation(Index, Key) of
                {not_found, Index1} ->
                    Index2 = stage_row(Key, Row, Index1),
                    {new, cache_put(Key, Row, Index2)};
                {{ok, Row}, Index1} ->
                    {replay, Index1};
                {{ok, _Other}, _Index1} ->
                    {error, outcome_index_conflict};
                {{error, Reason}, _Index1} ->
                    {error, Reason}
            end;
        error ->
            {error, outcome_index_bad_operation}
    end;
claim_operation(_Index, _Slot, _Claim, _OutcomeRef) ->
    {error, outcome_index_bad_operation}.

operation_candidate(
  #index{ns = Ns, anchor = Anchor} = Index,
  #{key := {<<_:256>> = User, <<_:256>> = OperationId},
    digest := <<_:256>> = Digest,
    target := {Ns, Anchor},
    operation_ref :=
      {operation, Ns, Anchor, User, OperationId} = OperationRef},
  OutcomeRef, Slot) ->
    case operation_outcome_ref(OutcomeRef, {Ns, Anchor}) of
        true ->
            Key = operation_key(Index, User, OperationId),
            {ok, Key,
             #{type => operation, ref => OperationRef,
               request_digest => Digest, outcome_ref => OutcomeRef,
               first_slot => Slot}};
        false ->
            error
    end;
operation_candidate(_Index, _Claim, _OutcomeRef, _Slot) ->
    error.

operation_outcome_ref(
  {transaction, Ns, Anchor, <<_:256>>}, {Ns, Anchor}) -> true;
operation_outcome_ref(
  {group, Ns, Anchor, <<_:256>>, <<_:256>>, <<_:256>>},
  {Ns, Anchor}) -> true;
operation_outcome_ref(_Ref, _Target) -> false.

lookup_operation(Index, Key) ->
    case cache_get(Key, Index) of
        {{ok, Row}, Index1} -> {{ok, Row}, Index1};
        {not_found, Index1} ->
            case backend_lookup(Index1, Key) of
                {ok, Row} -> {{ok, Row}, cache_put(Key, Row, Index1)};
                not_found -> {not_found, Index1};
                {error, Reason} -> {{error, Reason}, Index1}
            end
    end.

-doc "Look up an anchored transaction reference through the owner-held index.".
-spec lookup_ref(index(), term()) ->
          {{ok, outcome()} | {error, index_error()} |
           not_found | wrong_anchor, index()}.
lookup_ref(Index = #index{ns = Ns, anchor = Anchor},
           {transaction, Ns, Anchor, <<_:256>> = TxId}) ->
    lookup_tx(Index, TxId);
lookup_ref(Index = #index{ns = Ns, anchor = Anchor},
           {group, Ns, Anchor, <<_:256>> = Coordinator,
            <<_:256>> = Admission, <<_:256>> = GroupId} = Ref) ->
    lookup_group_ref(Index, Ref, Coordinator, Admission, GroupId);
lookup_ref(Index = #index{ns = Ns, anchor = Anchor},
           {operation, Ns, Anchor, <<_:256>> = User,
            <<_:256>> = OperationId}) ->
    lookup_operation(Index, operation_key(Index, User, OperationId));
lookup_ref(Index = #index{ns = Ns},
           {transaction, Ns, <<_:256>>, <<_:256>>}) ->
    {wrong_anchor, Index};
lookup_ref(Index = #index{ns = Ns},
           {group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}) ->
    {wrong_anchor, Index};
lookup_ref(Index = #index{ns = Ns},
           {operation, Ns, <<_:256>>, <<_:256>>, <<_:256>>}) ->
    {wrong_anchor, Index};
lookup_ref(Index, _Ref) ->
    {not_found, Index}.

lookup_group_ref(Index, Ref, Coordinator, Admission, GroupId) ->
    case lookup_group(Index, GroupId) of
        {{ok, #{ref := Ref} = Row}, Index1} ->
            {{ok, group_outcome(Ref, Row, applied_floor(Index1))}, Index1};
        {{ok, _ParticipantOnlyOrOtherOrigin}, Index1} ->
            pending_group_ref(
              Index1, Ref, Coordinator, Admission, GroupId);
        {not_found, Index1} ->
            pending_group_ref(
              Index1, Ref, Coordinator, Admission, GroupId);
        {{error, Reason}, Index1} ->
            {{error, Reason}, Index1}
    end.

pending_group_ref(Index = #index{dtx = Dtx}, Ref,
                  Coordinator, Admission, GroupId) ->
    case maps:get(pending_begin, Dtx) of
        #{lane := {Admission, Coordinator}, group_id := GroupId} ->
            {{ok, #{type => group, ref => Ref,
                    status => {pending, pending_begin}}}, Index};
        _ ->
            {not_found, Index}
    end.

group_outcome(Ref, #{terminal := #{slot := Slot}}, Floor)
  when Slot > Floor ->
    #{type => group, ref => Ref, status => {pending, publication}};
group_outcome(
  Ref, #{terminal := Terminal, history := History, result := Result}, _Floor)
  when Terminal =/= none ->
    #{type => group, ref => Ref,
      status => terminal_group_status(Terminal, Result, History)};
group_outcome(Ref, #{history := History}, _Floor) ->
    Phase = case maps:find(decision, maps:get(records, History)) of
                {ok, #{record := {quod_dtx_decision, 2, _, _, commit, _, none}}} ->
                    finalizing_commit;
                {ok, #{record := {quod_dtx_decision, 2, _, _, abort, _, _}}} ->
                    finalizing_abort;
                error -> begun
            end,
    #{type => group, ref => Ref, status => {pending, Phase}}.

terminal_group_status(
  #{verdict := commit, slot := Slot, participant_slots := Slots},
  Result, _History) ->
    {committed, Slot, Result, Slots};
terminal_group_status(
  #{verdict := abort, slot := Slot, participant_slots := Slots},
  _Result, History) ->
    {aborted, Slot, history_record(decision, History), Slots}.

-doc "Read one indexed transaction while its ontology is running or stopped.".
-spec lookup_live(binary(), file:filename_all(), binary()) ->
          {ok, map()} | {error, not_found | ontology_unreachable |
                                outcome_index_corrupt}.
lookup_live(Ns, LedgerDir, <<_:256>> = TxId)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    Path = filename:join(quod_ledger_store:ns_dir(LedgerDir, Ns),
                         "outcomes.dets"),
    case dets:info(Path) of
        undefined -> lookup_closed(Path, Ns, TxId);
        _ -> lookup_table(Path, Ns, TxId)
    end;
lookup_live(_Ns, _LedgerDir, _TxId) ->
    {error, not_found}.

lookup_closed(Path, Ns, TxId) ->
    Reader = {quod_outcome_reader, make_ref()},
    case dets:open_file(
           Reader, [{file, Path}, {type, set}, {keypos, 1},
                    {access, read}, {repair, false}]) of
        {ok, Reader} ->
            try lookup_table(Reader, Ns, TxId)
            after _ = dets:close(Reader)
            end;
        {error, {file_error, _Path, enoent}} -> {error, not_found};
        {error, enoent} -> {error, not_found};
        {error, _Reason} -> {error, ontology_unreachable}
    end.

lookup_table(Name, Ns, TxId) ->
    try dets:lookup(Name, meta) of
        [{meta, ?FORMAT, <<_:256>> = Anchor}] ->
            Key = {tx, Anchor, TxId},
            case dets:lookup(Name, Key) of
                [{Key, #{ref := {transaction, Ns, Anchor, TxId}} = Stored}] ->
                    case valid_stored(Key, Stored) of
                        true -> public(Stored);
                        false -> {error, outcome_index_corrupt}
                    end;
                [] -> {error, not_found};
                _ -> {error, outcome_index_corrupt}
            end;
        _ -> {error, outcome_index_corrupt}
    catch
        error:badarg -> {error, ontology_unreachable};
        exit:_ -> {error, ontology_unreachable}
    end.

lookup_tx(Index, TxId) ->
    Key = tx_key(Index, TxId),
    case cache_get(Key, Index) of
        {{ok, Outcome}, Index1} ->
            {{ok, Outcome}, Index1};
        {not_found, Index1} ->
            case backend_lookup(Index1, Key) of
                {ok, #{status := pending} = Outcome} ->
                    {{ok, Outcome}, Index1};
                {ok, Outcome} ->
                    {{ok, Outcome}, cache_put(Key, Outcome, Index1)};
                not_found ->
                    {not_found, Index1};
                {error, Reason} ->
                    {{error, Reason}, Index1}
            end
    end.

-doc "Return the bounded public classification, or a typed corruption error.".
-spec public(outcome() | term()) -> {ok, map()} | {error, outcome_index_corrupt}.
public(#{status := Status,
         ref := {transaction, Ns, <<_:256>>, <<_:256>>} = Ref})
  when is_binary(Ns), byte_size(Ns) > 0 ->
    case public_status(Status) of
        {ok, Public} -> {ok, Public#{ref => Ref}};
        error -> {error, outcome_index_corrupt}
    end;
public(#{type := group,
         ref := {group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>} = Ref,
         status := Status})
  when is_binary(Ns), byte_size(Ns) > 0 ->
    public_group_status(Status, Ref);
public(#{type := operation,
         ref := {operation, Ns, <<_:256>>, <<_:256>>, <<_:256>>} = Ref,
         request_digest := <<_:256>> = RequestDigest,
         outcome_ref := OutcomeRef, first_slot := Slot})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Slot), Slot > 0 ->
    {ok, #{status => claimed, ref => Ref,
           request_digest => RequestDigest,
           outcome_ref => OutcomeRef, height => Slot}};
public(_Other) ->
    {error, outcome_index_corrupt}.

public_status(pending) -> {ok, #{status => pending}};
public_status({committed, Slot}) when is_integer(Slot), Slot > 0 ->
    {ok, #{status => committed, height => Slot}};
public_status({rejected, Reason, Slot})
  when is_atom(Reason), is_integer(Slot), Slot > 0 ->
    {ok, #{status => rejected, reason => Reason, height => Slot}};
public_status(_Other) -> error.

public_group_status({pending, Phase}, Ref)
  when Phase =:= pending_begin; Phase =:= begun;
       Phase =:= finalizing_commit; Phase =:= finalizing_abort;
       Phase =:= publication ->
    {ok, #{status => pending, phase => Phase, ref => Ref}};
public_group_status({committed, Slot, Result, Slots}, Ref)
  when is_integer(Slot), Slot > 0 ->
    case {quod_durable_term:decode_result(Result),
          valid_participant_slots(Slots)} of
        {{ok, Bindings}, true} ->
            {ok, #{status => committed, height => Slot, ref => Ref,
                   bindings => Bindings, participant_slots => Slots}};
        _ ->
            {error, outcome_index_corrupt}
    end;
public_group_status(
  {aborted, Slot,
   {quod_dtx_decision, 2, _, _, abort, _, _} = Decision, Slots}, Ref)
  when is_integer(Slot), Slot > 0 ->
    case {quod_dtx:decision_failure_reasons(Decision),
          valid_participant_slots(Slots)} of
        {{ok, Reasons}, true} ->
            {ok, #{status => aborted, height => Slot, ref => Ref,
                   reasons => Reasons, participant_slots => Slots}};
        _ ->
            {error, outcome_index_corrupt}
    end;
public_group_status(_, _) ->
    {error, outcome_index_corrupt}.

tx_key(#index{anchor = Anchor}, TxId) -> {tx, Anchor, TxId}.
group_key(#index{anchor = Anchor}, GroupId) -> {group, Anchor, GroupId}.
operation_key(#index{anchor = Anchor}, User, OperationId) ->
    {operation, Anchor, User, OperationId}.
state_key(Anchor) -> {dtx_state, Anchor}.

backend_lookup(#index{staged = Staged}, Key) when is_map_key(Key, Staged) ->
    stored_result(Key, maps:get(Key, Staged));
backend_lookup(#index{backend = {dets, Name}}, Key) ->
    try dets:lookup(Name, Key) of
        [{Key, Value}] ->
            case valid_stored(Key, Value) of
                true -> {ok, Value};
                false -> invalidate_backend(Name, corrupt_row)
            end;
        [] -> not_found;
        {error, Reason} -> invalidate_backend(Name, Reason);
        Other -> invalidate_backend(Name, {bad_lookup, Other})
    catch
        Class:Reason -> invalidate_backend(Name, {Class, Reason})
    end;
backend_lookup(#index{backend = {memory, Map}}, Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> stored_result(Key, Value);
        error -> not_found
    end.

stored_result(Key, Value) ->
    case valid_stored(Key, Value) of
        true -> {ok, Value};
        false -> {error, outcome_index_conflict}
    end.

valid_stored(
  {tx, Anchor, TxId},
  #{ref := {transaction, Ns, Anchor, TxId},
    tx_id := TxId, plan_digest := <<_:256>>, status := Status})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(TxId), byte_size(TxId) =:= 32 ->
    valid_status(Status);
valid_stored({group, Anchor, GroupId}, Row)
  when is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(GroupId), byte_size(GroupId) =:= 32 ->
    valid_group_row(Row, GroupId, Anchor);
valid_stored(
  {operation, Anchor, User, OperationId},
  #{type := operation,
    ref := {operation, Ns, Anchor, User, OperationId},
    request_digest := <<_:256>>,
    outcome_ref := OutcomeRef, first_slot := Slot} = Row)
  when map_size(Row) =:= 5,
       is_binary(Ns), byte_size(Ns) > 0,
       is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(User), byte_size(User) =:= 32,
       is_binary(OperationId), byte_size(OperationId) =:= 32,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64 ->
    operation_outcome_ref(OutcomeRef, {Ns, Anchor});
valid_stored(_Key, _Value) ->
    false.

valid_status(pending) -> true;
valid_status({committed, Slot}) -> is_integer(Slot) andalso Slot > 0;
valid_status({rejected, Reason, Slot}) ->
    is_atom(Reason) andalso is_integer(Slot) andalso Slot > 0;
valid_status(_Status) -> false.

valid_dtx_state(
  #{pending_begin := Pending, projection := Projection,
    applied_floor := Floor} = Dtx, Target)
  when map_size(Dtx) =:= 3,
       is_integer(Floor), Floor >= 0, Floor =< ?MAX_UINT64 ->
    valid_pending_begin(Pending) andalso
        valid_projection(Projection, Target);
valid_dtx_state(_, _) -> false.

valid_pending_begin(none) -> true;
valid_pending_begin(Pending) ->
    normalize_pending_begin(Pending) =:= {ok, Pending}.

valid_group_row(
  #{history := History, ref := Ref, result := Result,
    applied := Applied, terminal := Terminal} = Row,
  GroupId, Anchor)
  when map_size(Row) =:= 5 ->
    valid_history(History, GroupId) andalso
        valid_group_ref(Ref, GroupId, Anchor) andalso
        valid_result_blob(Result) andalso valid_applied(Applied) andalso
        valid_terminal(Terminal, History, Result) andalso
        row_relations(Row);
valid_group_row(_, _, _) -> false.

valid_group_ref(none, _GroupId, _Anchor) -> true;
valid_group_ref(
  {group, Ns, Anchor, <<_:256>>, <<_:256>>, GroupId}, GroupId, Anchor)
  when is_binary(Ns), byte_size(Ns) > 0 -> true;
valid_group_ref(_, _, _) -> false.

valid_result_blob(none) -> true;
valid_result_blob(Blob) when is_binary(Blob) ->
    case quod_durable_term:decode_result(Blob) of
        {ok, _} -> true;
        {error, _} -> false
    end;
valid_result_blob(_) -> false.

valid_applied(none) -> true;
valid_applied(#{verdict := Verdict, finalize_ref := Ref,
                slot := Slot, generation := Generation} = Applied)
  when map_size(Applied) =:= 4,
       (Verdict =:= commit orelse Verdict =:= abort),
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    quod_dtx:validate_certified_ref(Ref) andalso ref_slot(Ref) =:= Slot;
valid_applied(_) -> false.

valid_terminal(none, _History, _Result) -> true;
valid_terminal(
  #{verdict := Verdict, complete_ref := Ref, slot := Slot,
    participant_slots := Slots} = Terminal,
  History, Result)
  when map_size(Terminal) =:= 4,
       (Verdict =:= commit orelse Verdict =:= abort),
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64 ->
    case terminal_decision(History, Ref) of
        {ok, Decision} ->
            quod_dtx:validate_certified_ref(Ref) andalso
                ref_slot(Ref) =:= Slot andalso
                valid_participant_slots(Slots) andalso
                valid_terminal_payload(Verdict, Result, Decision);
        error -> false
    end;
valid_terminal(_, _, _) -> false.

terminal_decision(
  #{records :=
      #{decision := #{record := Decision}, complete := #{ref := Ref}}}, Ref) ->
    {ok, Decision};
terminal_decision(_, _) -> error.

valid_terminal_payload(commit, Result, Decision) ->
    valid_result_blob(Result) andalso
        quod_dtx:decision_failure_reasons(Decision) =:= none;
valid_terminal_payload(abort, Result, Decision) ->
    valid_result_blob(Result) andalso
    case quod_dtx:decision_failure_reasons(Decision) of
        {ok, [_ | _]} -> true;
        _ -> false
    end.

row_relations(#{ref := none, result := none, terminal := none}) -> true;
row_relations(#{ref := {group, _, _, _, _, _}, result := Result})
  when is_binary(Result) -> true;
row_relations(_) -> false.

valid_participant_slots(Slots) ->
    valid_participant_slots(Slots, none, 0).

valid_participant_slots([], _Previous, Count) -> Count >= 2;
valid_participant_slots([{Identity, Slot, Generation} | Rest], Previous, Count)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       (Previous =:= none orelse Previous < Identity),
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    valid_identity(Identity) andalso
        valid_participant_slots(Rest, Identity, Count + 1);
valid_participant_slots(_, _, _) -> false.

valid_history(#{group_id := GroupId, records := Records} = History, GroupId)
  when map_size(History) =:= 2, is_map(Records),
       map_size(Records) >= 1, map_size(Records) =< 5 ->
    valid_history_records(GroupId, maps:to_list(Records));
valid_history(_, _) -> false.

valid_history_records(_GroupId, []) -> true;
valid_history_records(
  GroupId,
  [{decision,
    #{group_id := GroupId, digest := <<_:256>> = Digest,
      ref := Ref,
      record := {quod_dtx_decision, 2, GroupId, _, _, _, _} = Record} = Entry}
   | Rest])
  when map_size(Entry) =:= 4 ->
    quod_dtx:validate_certified_ref(Ref) andalso
        ref_record_digest(Ref) =:= Digest andalso
        quod_dtx:record_digest(Record) =:= Digest andalso
        valid_decision_record(Record) andalso
        valid_history_records(GroupId, Rest);
valid_history_records(
  GroupId,
  [{Kind, #{group_id := GroupId, digest := <<_:256>> = Digest,
            ref := Ref} = Entry} | Rest])
  when map_size(Entry) =:= 3 ->
    valid_dtx_kind(Kind) andalso quod_dtx:validate_certified_ref(Ref) andalso
        ref_record_digest(Ref) =:= Digest andalso
        valid_history_records(GroupId, Rest);
valid_history_records(_, _) -> false.

valid_decision_record({quod_dtx_decision, 2, _, _, commit, _Rows, none}) ->
    true;
valid_decision_record(
  {quod_dtx_decision, 2, _, _, abort, _Rows, _} = Decision) ->
    case quod_dtx:decision_failure_reasons(Decision) of
        {ok, [_ | _]} -> true;
        _ -> false
    end;
valid_decision_record(_) -> false.

valid_dtx_kind('begin') -> true;
valid_dtx_kind(prepare) -> true;
valid_dtx_kind(decision) -> true;
valid_dtx_kind(finalize) -> true;
valid_dtx_kind(complete) -> true;
valid_dtx_kind(_) -> false.

valid_projection(
  #{target := Target} = Projection, Target) ->
    quod_dtx:valid_projection(Projection);
valid_projection(_, _) -> false.

valid_identity({Ns, <<_:256>>}) when is_binary(Ns), byte_size(Ns) > 0 -> true;
valid_identity(_) -> false.


history_ref(Kind, #{records := Records}) ->
    maps:get(ref, maps:get(Kind, Records)).

history_record(Kind, #{records := Records}) ->
    maps:get(record, maps:get(Kind, Records)).

exact_history_ref(Kind, Ref, History) ->
    history_ref(Kind, History) =:= Ref.

certified_ref_identity(
  {quod_dtx_ref, 2, Ns, Anchor, _, _, _, _}) -> {Ns, Anchor}.
ref_slot({quod_dtx_ref, 2, _, _, Slot, _, _, _}) -> Slot.
ref_record_digest({quod_dtx_ref, 2, _, _, _, _, Digest, _}) -> Digest.

backend_put(Index = #index{backend = {dets, Name}}, Key, Value) ->
    case dets_write(Name, {Key, Value}) of
        ok -> {ok, Index};
        {error, Reason} -> invalidate_backend(Name, Reason)
    end;
backend_put(Index = #index{backend = {memory, Map}}, Key, Value) ->
    {ok, Index#index{backend = {memory, Map#{Key => Value}}}}.

stage_terminal(Index = #index{staged = Staged}, Key, Value) ->
    Index#index{staged = Staged#{Key => Value}}.

-doc "Persist every terminal row staged by the current committed block in one write.".
-spec flush(index()) -> {ok, index()} | {error, index_error()}.
flush(Index = #index{staged = Staged}) when map_size(Staged) =:= 0 ->
    {ok, Index};
flush(Index = #index{backend = {dets, Name}, staged = Staged}) ->
    case dets_write(Name, maps:to_list(Staged)) of
        ok -> {ok, mark_flushed(Index, Staged)};
        {error, Reason} -> invalidate_backend(Name, Reason)
    end;
flush(Index = #index{backend = {memory, Map}, staged = Staged}) ->
    Index1 = Index#index{backend = {memory, maps:merge(Map, Staged)}},
    {ok, mark_flushed(Index1, Staged)}.

mark_flushed(Index = #index{anchor = Anchor}, Staged) ->
    Floor = case maps:find(state_key(Anchor), Staged) of
                {ok, Dtx} -> maps:get(applied_floor, Dtx);
                error -> Index#index.applied_floor
            end,
    Index#index{staged = #{}, applied_floor = Floor}.

backend_delete(Index = #index{backend = {dets, Name}}, Key) ->
    case dets_delete(Name, Key) of
        ok -> {ok, remove_transient(Key, Index)};
        {error, Reason} -> invalidate_backend(Name, Reason)
    end;
backend_delete(Index = #index{backend = {memory, Map}}, Key) ->
    {ok, remove_transient(
           Key, Index#index{backend = {memory, maps:remove(Key, Map)}})}.

remove_transient(Key, Index = #index{staged = Staged, cache = Cache,
                                      order = Order}) ->
    case maps:take(Key, Cache) of
        {{Clock, _Outcome}, Cache1} ->
            Index#index{staged = maps:remove(Key, Staged),
                        cache = Cache1,
                        order = gb_trees:delete(Clock, Order)};
        error ->
            Index#index{staged = maps:remove(Key, Staged)}
    end.

%% A pending reference is returned only after this sync succeeds. Terminal
%% rows share one insert+sync per committed block, retaining batching without
%% weakening crash durability.
dets_write(Name, Objects) ->
    dets_mutate(Name, fun() -> dets:insert(Name, Objects) end).

dets_delete(Name, Key) ->
    dets_mutate(Name, fun() -> dets:delete(Name, Key) end).

dets_mutate(Name, Mutation) ->
    try
        case Mutation() of
            ok -> dets:sync(Name);
            {error, _} = Error -> Error
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% The DETS file is a rebuildable projection, not authoritative state. Once
%% DETS latches a table-level error, continuing or reopening the same file can
%% only repeat the failure. Close and remove that one derived file before the
%% owner stops; the namespace supervisor then opens a fresh index and ledger
%% replay deterministically reconstructs every terminal row.
invalidate_backend(Name, Reason) ->
    _ = dets:close(Name),
    Reset = case file:delete(Name) of
                ok -> reset;
                {error, enoent} -> reset;
                {error, DeleteReason} -> {reset_failed, DeleteReason}
            end,
    {error, {outcome_index_io, {Reason, Reset}}}.

cache_get(Key, Index = #index{cache = Cache}) ->
    case maps:find(Key, Cache) of
        {ok, {_OldClock, Outcome}} ->
            Index1 = cache_put(Key, Outcome, Index),
            {{ok, Outcome}, Index1};
        error ->
            {not_found, Index}
    end.

cache_put(Key, Outcome,
          Index = #index{cache = Cache0, order = Order0, clock = Clock0}) ->
    Order1 = case maps:find(Key, Cache0) of
                 {ok, {OldClock, _}} -> gb_trees:delete(OldClock, Order0);
                 error -> Order0
             end,
    Clock = Clock0 + 1,
    Cache1 = Cache0#{Key => {Clock, Outcome}},
    Order2 = gb_trees:insert(Clock, Key, Order1),
    trim_cache(Index#index{cache = Cache1, order = Order2, clock = Clock}).

trim_cache(Index = #index{cache = Cache})
  when map_size(Cache) =< ?CACHE_LIMIT -> Index;
trim_cache(Index = #index{cache = Cache0, order = Order0}) ->
    {OldClock, OldKey} = gb_trees:smallest(Order0),
    trim_cache(
      Index#index{cache = maps:remove(OldKey, Cache0),
                  order = gb_trees:delete(OldClock, Order0)}).
