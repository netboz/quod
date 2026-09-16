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
journal-derived local pending-Vote identities, the ledger-active own-role
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
         check_completion/4, complete_operation/5, unresolved_operations/1,
         ref_identity/1, lookup_ref/2, lookup_live/3, public/1,
         project_pending_votes/2, dtx_state/1,
         lookup_group/2, group_history/2,
         apply_dtx/2, advance_applied/2, applied_floor/1, changed_requests/1]).

-export_type([index/0, outcome/0]).

-define(FORMAT, 8). %% own-role Vote/Resolve/Complete projection
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

-doc "Request identities changed by the pending flush; reads no durable rows.".
-spec changed_requests(index()) -> [term()].
changed_requests(#index{staged = Staged}) ->
    [{request, {Agent, Id}} ||
      #{type := operation, ref := {operation, _, _, Agent, Id}} <- maps:values(Staged)].

-type outcome() ::
        #{ref := {transaction, binary(), binary(), binary()},
          tx_id := binary(), plan_digest := binary(),
          status := pending | {committed, pos_integer()} |
                    {rejected, atom(), pos_integer()}} |
        #{type := group,
          ref := {group, binary(), <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>},
          status := term()} |
        #{type := operation,
          ref := {operation, binary(), <<_:256>>, binary(), <<_:256>>},
          request_digest := <<_:256>>,
          outcome_ref := term(), first_slot := pos_integer(),
          state := unresolved | {terminal, pos_integer()}}.
-type pending_vote() ::
        {group, binary(), <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}.
-type index_error() :: outcome_index_bad_transaction |
                       outcome_index_bad_group |
                       outcome_index_bad_operation |
                       outcome_index_gap |
                       outcome_index_conflict |
                       {outcome_index_io, term()}.
-type deferred_resolve_ack() ::
        {resolve_applied, <<_:256>>, pos_integer(), non_neg_integer()}.

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
  {operation, Ns, <<_:256>> = Anchor, AgentRef, <<_:256>>})
  when is_binary(Ns), byte_size(Ns) > 0 ->
    case quod_agent_ref:valid_principal({agent, AgentRef}) of
        true -> {ok, {Ns, Anchor}};
        false -> error
    end;
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
        [{meta, Version, _OldAnchor}] when is_integer(Version), Version < ?FORMAT ->
            _ = dets:close(Name),
            {error, {unsupported_format, Version}};
        Other ->
            %% Corrupt derived state may be reconstructed; a recognized old
            %% format above is refused by name without deleting its bytes.
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
%% suppress the prepared Resolve effect that reconstructs D.  Ordinary
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
    #{pending_votes => #{},
      projection => quod_atomic:initial_projection({Ns, Anchor}, 0),
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

-doc "Replace all rebuildable local pending-Vote identities from the journal.".
-spec project_pending_votes(index(), [pending_vote()]) ->
          {ok, index()} | {error, index_error()}.
project_pending_votes(Index = #index{ns = Ns, anchor = Anchor, dtx = Dtx}, PendingRows)
  when is_list(PendingRows) ->
    case normalize_pending_votes(PendingRows, {Ns, Anchor}, #{}) of
        {ok, Pending} ->
            case maps:get(pending_votes, Dtx) of
                Pending -> {ok, Index};
                _ -> {ok, stage_dtx_state(Index, Dtx#{pending_votes := Pending})}
            end;
        error -> {error, outcome_index_bad_group}
    end.

normalize_pending_votes([], _Target, Acc) -> {ok, Acc};
normalize_pending_votes([{group, _, _, _, _, <<_:256>> = Id} = Ref | Rest], Target, Acc) ->
    case ref_identity(Ref) of
        {ok, Target} when not is_map_key(Id, Acc) ->
            normalize_pending_votes(Rest, Target, Acc#{Id => Ref});
        {ok, Other} when Other =/= Target ->
            %% A participant journal has no local public source waiter.
            normalize_pending_votes(Rest, Target, Acc);
        _ -> error
    end;
normalize_pending_votes(_, _, _) -> error.

-doc "Current owner-held DTX projection, including staged owner-local updates.".
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
            %% Every fact in this block has been applied before this boundary.
            %% A whole reducer wave may carry several fences: acknowledge them
            %% together here, so a later item cannot resurrect an earlier one.
            Projection = maps:get(projection, Dtx),
            Applied = maps:fold(
              fun(Id, #{slot := H, generation := Gen}, Acc) when H =< Slot ->
                      {ok, Next} = quod_atomic:acknowledge_resolve(Id, H, Gen, Acc),
                      Next;
                 (_, _, Acc) -> Acc
              end, Projection, maps:get(apply_fences, Projection)),
            {ok, stage_dtx_state(
                   Index, Dtx#{applied_floor := Slot, projection := Applied})};
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
          {quod_atomic:group_history(), index()} | {error, index_error()}.
group_history(Index, <<_:256>> = GroupId) ->
    case lookup_group(Index, GroupId) of
        {{ok, #{history := History}}, Index1} -> {History, Index1};
        {not_found, Index1} -> {quod_atomic:initial_group_history(), Index1};
        {{error, Reason}, _Index1} -> {error, Reason}
    end;
group_history(_Index, _GroupId) ->
    {error, outcome_index_bad_group}.

-doc """
Stage one item returned by the canonical atomic reducer.

This is an owner-local adapter, not a second validator or a wire admission
boundary. The committed materializer authenticates the whole wave and reduces
it once before applying any effects. This adapter stores that exact result;
it never re-decodes plans, rechecks signatures or mirrors the transition graph.
Contradictions in this internal contract remain loud.

The caller applies the item's facts before staging it. The returned
`resolve_applied` token must remain deferred until the block's common
`advance_applied/2` -> `flush/1` -> MVCC publication boundary succeeds.
""".
-spec apply_dtx(index(), map()) ->
          {ok, index(), none | deferred_resolve_ack()} | {error, index_error()}.
apply_dtx(Index0 = #index{ns = Ns, anchor = Anchor},
          #{control := Control, ref := Ref, history := History,
            projection := Projection, effects := Effects}) ->
    {Ns, Anchor} = quod_atomic:control_target(Control),
    Id = quod_atomic:group_id(Control),
    Kind = quod_atomic:control_kind(Control),
    case lookup_group(Index0, Id) of
        {{error, Reason}, _} -> {error, Reason};
        {Found, Index = #index{dtx = Dtx}} ->
            OldRow = case Found of
                         {ok, Existing} -> Existing;
                         not_found -> empty_group_row()
                     end,
            case maps:is_key(Kind, maps:get(records, maps:get(history, OldRow))) of
                true ->
                    %% The reducer made duplicates effect-free and retained
                    %% the first reference, even with another valid QC subset.
                    [] = Effects,
                    History = maps:get(history, OldRow),
                    {ok, Index, none};
                false ->
                    Row = capture_control(Control, Ref, Effects, OldRow#{history := History}),
                    Ack = case Effects of
                        [{resolved, Id, _, _, Ref, Generation}] ->
                            {resolve_applied, Id, ref_slot(Ref), Generation};
                        _ -> none
                    end,
                    Dtx1 = Dtx#{pending_votes := maps:remove(Id, maps:get(pending_votes, Dtx)),
                                projection := Projection},
                    Key = group_key(Index, Id),
                    Index1 = stage_row(Key, Row, stage_dtx_state(Index, Dtx1)),
                    {ok, cache_put(Key, Row, Index1), Ack}
            end
    end.

stage_row(Key, Row, Index = #index{staged = Staged}) ->
    Index#index{staged = Staged#{Key => Row}}.

empty_group_row() ->
    #{history => quod_atomic:initial_group_history(), ref => none,
      result => none, applied => none, terminal => none}.

capture_control(Control, Ref, Effects, Row) ->
    Material = quod_atomic:control_material(Control),
    case Material of
        {{quod_dtx_vote, 4, _, Target, _, _}, _,
         #{group := #{origin := Target} = Binding}} ->
            Row#{ref := group_ref(Binding), result := maps:get(result, Binding)};
        {{quod_dtx_vote, 4, _, _, _, _}, _, _} ->
            Row;
        {{quod_dtx_resolve, 4, Id, Target, ManifestDigest, Outcome, _, _, _, Generation, _}, _,
         #{reasons := Reasons}} ->
            [{resolved, Id, Outcome, OwnMaterial, Ref, Generation}] = Effects,
            Applied = #{verdict => Outcome, resolve_ref => Ref, slot => ref_slot(Ref),
                        generation => Generation, reasons => Reasons,
                        manifest_digest => ManifestDigest,
                        plan_digest => resolved_plan_digest(Target, OwnMaterial)},
            %% Keep only the exact binding needed by private-effect recovery,
            %% not its plan or another role's material. Unvoted tombstones
            %% carry the manifest binding but cannot invent an own-plan digest.
            Row#{applied := Applied};
        {{quod_dtx_complete, 4, _, _, _, _, Resolves, _}, _, _} ->
            Row#{terminal := #{complete_ref => Ref,
                participant_slots => [{T, ref_slot(R), G} || {T, R, G} <- Resolves]}}
    end.

resolved_plan_digest(_Target, none) -> none;
resolved_plan_digest(Target, {_, _, #{plans := Plans}}) ->
    case maps:get(Target, Plans, none) of
        none -> none;
        Plan -> quod_dtx:digest(Plan)
    end.

group_ref(#{origin := {Ns, Anchor}, coordinator := Coordinator,
            admission := Admission, group_id := Id}) ->
    {group, Ns, Anchor, Coordinator, Admission, Id}.

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
                {{ok, Existing}, Index1} ->
                    case completed_operation_claim_replay(Existing, Row) of
                        true -> {replay, Index1};
                        false -> {error, outcome_index_conflict}
                    end;
                {{error, Reason}, _Index1} ->
                    {error, Reason}
            end;
        error ->
            {error, outcome_index_bad_operation}
    end;
claim_operation(_Index, _Slot, _Claim, _OutcomeRef) ->
    {error, outcome_index_bad_operation}.

%% A restart opens the durable outcome index before replaying its ledger.
%% The persisted row may therefore already include the later completion when
%% replay reaches the earlier claim.  Its immutable claim fields must still
%% match exactly; only the monotonic unresolved -> terminal state may differ.
completed_operation_claim_replay(
  #{type := operation, ref := Ref, request_digest := RequestDigest,
    outcome_ref := OutcomeRef, first_slot := FirstSlot,
    state := {terminal, TerminalSlot}},
  #{type := operation, ref := Ref, request_digest := RequestDigest,
    outcome_ref := OutcomeRef, first_slot := FirstSlot,
    state := unresolved}) ->
    is_integer(TerminalSlot) andalso TerminalSlot > FirstSlot;
completed_operation_claim_replay(_Existing, _Claim) ->
    false.

operation_candidate(
  #index{ns = Ns, anchor = Anchor} = Index,
  #{key := {AgentRef, <<_:256>> = OperationId},
    digest := <<_:256>> = Digest,
    target := {Ns, Anchor},
    operation_ref :=
      {operation, Ns, Anchor, AgentRef, OperationId} = OperationRef},
  OutcomeRef, Slot) ->
    case quod_agent_ref:valid_principal({agent, AgentRef}) andalso
         operation_outcome_ref(OutcomeRef) of
        true ->
            Key = operation_key(Index, AgentRef, OperationId),
            State = case OutcomeRef of
                        {applications, _Refs} -> unresolved;
                        _ ->
                            case quod_outcome:ref_identity(OutcomeRef) of
                                {ok, {Ns, Anchor}} -> {terminal, Slot};
                                {ok, _Foreign} -> unresolved
                            end
                    end,
            {ok, Key,
             #{type => operation, ref => OperationRef,
               request_digest => Digest, outcome_ref => OutcomeRef,
               %% `included` is the durable row's receipt field, not a verdict.
               %% [] means no source receipt; the certified vector installs once.
               included => [], first_slot => Slot, state => State}};
        false ->
            error
    end;
operation_candidate(_Index, _Claim, _OutcomeRef, _Slot) ->
    error.

operation_outcome_ref({applications, Refs}) ->
    quod_operation_vector:references(Refs) =:= {ok, Refs};
operation_outcome_ref({transaction, Ns, <<_:256>>, <<_:256>>}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0;
operation_outcome_ref(
  {group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0;
operation_outcome_ref(_Ref) -> false.

-doc "Check a complete receipt vector; only certified arms carry authenticated target verdicts.".
-spec check_completion(index(), term(), <<_:256>>, term()) ->
          {new, index()} | {replay, index()} | {error, index_error()}.
check_completion(Index,
                 {operation, Ns, Anchor, AgentRef, OperationId} = OperationRef,
                 <<_:256>> = Digest, Receipt) ->
    case {Ns =:= Index#index.ns, Anchor =:= Index#index.anchor,
          quod_operation_vector:receipt_references(Receipt)} of
        {true, true, {ok, Refs}} ->
            Key = operation_key(Index, AgentRef, OperationId),
            case lookup_operation(Index, Key) of
                {{ok, #{ref := OperationRef, request_digest := Digest,
                        outcome_ref := {applications, Refs},
                        included := [], state := unresolved}},
                 Index1} -> {new, Index1};
                {{ok, #{ref := OperationRef, request_digest := Digest,
                        outcome_ref := {applications, Refs}, included := Existing,
                        state := {terminal, _}}}, Index1} ->
                    case quod_operation_vector:same_receipt(Existing, Receipt) of
                        true -> {replay, Index1};
                        false -> {error, outcome_index_conflict}
                    end;
                {{ok, _}, _Index1} -> {error, outcome_index_conflict};
                {not_found, _Index1} -> {error, outcome_index_bad_operation};
                {{error, Reason}, _Index1} -> {error, Reason}
            end;
        _ -> {error, outcome_index_bad_operation}
    end;
check_completion(_Index, _OperationRef, _Digest, _OutcomeRef) ->
    {error, outcome_index_bad_operation}.

-doc "Install the complete foreign-operation receipt and preserve its first terminal slot.".
-spec complete_operation(index(), pos_integer(), term(), <<_:256>>, term()) ->
          {new | replay, index()} | {error, index_error()}.
complete_operation(Index, Slot,
                   {operation, Ns, Anchor, AgentRef, OperationId} = OperationRef,
                   <<_:256>> = Digest, Receipt)
  when is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64 ->
    case {Ns =:= Index#index.ns, Anchor =:= Index#index.anchor,
          quod_operation_vector:receipt_references(Receipt)} of
        {true, true, {ok, Refs}} ->
            Key = operation_key(Index, AgentRef, OperationId),
            case lookup_operation(Index, Key) of
                {{ok, #{ref := OperationRef, request_digest := Digest,
                        outcome_ref := {applications, Refs},
                        included := [], state := unresolved} = Row},
                 Index1} ->
                    Row1 = Row#{included := Receipt, state := {terminal, Slot}},
                    Index2 = stage_row(Key, Row1, Index1),
                    {new, cache_put(Key, Row1, Index2)};
                {{ok, #{ref := OperationRef, request_digest := Digest,
                        outcome_ref := {applications, Refs}, included := ExistingReceipt,
                        state := {terminal, Existing}}}, Index1}
                  when Existing =< Slot ->
                    %% Honest replicas may submit receipts with different valid
                    %% certificate subsets for the same complete statements.
                    %% Compare semantic receipt identity and preserve the first
                    %% terminal slot; neither certificate bytes nor arrival order
                    %% may change an already-published outcome.
                    case quod_operation_vector:same_receipt(ExistingReceipt, Receipt) of
                        true -> {replay, Index1};
                        false -> {error, outcome_index_conflict}
                    end;
                {{ok, _Conflict}, _Index1} ->
                    {error, outcome_index_conflict};
                {not_found, _Index1} ->
                    {error, outcome_index_bad_operation};
                {{error, Reason}, _Index1} ->
                    {error, Reason}
            end;
        _ ->
            {error, outcome_index_bad_operation}
    end;
complete_operation(_Index, _Slot, _OperationRef, _Digest, _OutcomeRef) ->
    {error, outcome_index_bad_operation}.

-doc "Return durable foreign claims that still require target/receipt recovery.".
-spec unresolved_operations(index()) -> {[map()], index()}.
unresolved_operations(Index = #index{backend = {memory, Map}}) ->
    Rows = [Row || {_Key, #{type := operation, state := unresolved} = Row}
                       <- maps:to_list(Map)],
    {Rows, Index};
unresolved_operations(Index = #index{backend = {dets, Name}}) ->
    Pattern = {{operation, Index#index.anchor, '_', '_'},
               #{type => operation, ref => '_', request_digest => '_',
                 outcome_ref => '_', included => '_',
                 first_slot => '_', state => unresolved}},
    Rows = try [Row || {_Key, Row} <- dets:match_object(Name, Pattern)]
           catch _:_ -> []
           end,
    {Rows, Index}.

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
           {group, Ns, Anchor, <<_:256>>,
            <<_:256>>, <<_:256>> = GroupId} = Ref) ->
    lookup_group_ref(Index, Ref, GroupId);
lookup_ref(Index = #index{ns = Ns, anchor = Anchor},
           {operation, Ns, Anchor, AgentRef,
            <<_:256>> = OperationId}) ->
    case quod_agent_ref:valid_principal({agent, AgentRef}) of
        true -> lookup_operation(
                  Index, operation_key(Index, AgentRef, OperationId));
        false -> {not_found, Index}
    end;
lookup_ref(Index = #index{ns = Ns},
           {transaction, Ns, <<_:256>>, <<_:256>>}) ->
    {wrong_anchor, Index};
lookup_ref(Index = #index{ns = Ns},
           {group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}) ->
    {wrong_anchor, Index};
lookup_ref(Index = #index{ns = Ns},
           {operation, Ns, <<_:256>>, _AgentRef, <<_:256>>}) ->
    {wrong_anchor, Index};
lookup_ref(Index, _Ref) ->
    {not_found, Index}.

lookup_group_ref(Index, Ref, GroupId) ->
    case lookup_group(Index, GroupId) of
        {{ok, #{ref := Ref} = Row}, Index1} ->
            {{ok, group_outcome(Ref, Row, applied_floor(Index1))}, Index1};
        {{ok, _ParticipantOnlyOrOtherOrigin}, Index1} ->
            pending_group_ref(Index1, Ref, GroupId);
        {not_found, Index1} ->
            pending_group_ref(Index1, Ref, GroupId);
        {{error, Reason}, Index1} ->
            {{error, Reason}, Index1}
    end.

pending_group_ref(Index = #index{dtx = Dtx}, Ref, GroupId) ->
    case maps:get(GroupId, maps:get(pending_votes, Dtx), none) of
        Ref ->
            {{ok, #{type => group, ref => Ref,
                    status => {pending, pending_vote}}}, Index};
        _ ->
            {not_found, Index}
    end.

group_outcome(Ref, #{terminal := #{complete_ref := CompleteRef}} = Row, Floor) ->
    case ref_slot(CompleteRef) > Floor of
        true -> #{type => group, ref => Ref, status => {pending, publication}};
        false ->
            #{applied := #{verdict := Verdict, slot := Slot, reasons := Reasons},
              terminal := #{participant_slots := Slots}, result := Result} = Row,
            Status = case Verdict of
                         commit -> {committed, Slot, Result, Slots};
                         abort -> {aborted, Slot, Reasons, Slots}
                     end,
            #{type => group, ref => Ref, status => Status}
    end;
group_outcome(Ref, #{applied := Applied}, _Floor) ->
    Phase = case Applied of
                none -> voted;
                #{verdict := commit} -> resolving_commit;
                #{verdict := abort} -> resolving_abort
            end,
    #{type => group, ref => Ref, status => {pending, Phase}}.

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
         ref := {operation, Ns, <<_:256>>, AgentRef, <<_:256>>} = Ref,
         request_digest := <<_:256>> = RequestDigest,
         outcome_ref := OutcomeRef, included := Included,
         first_slot := Slot, state := State})
  when is_binary(Ns), byte_size(Ns) > 0, is_binary(AgentRef),
       is_integer(Slot), Slot > 0 ->
    PublicState = case State of
                      unresolved -> unresolved;
                      {terminal, _} -> terminal
                  end,
    ReceiptHeight = case State of unresolved -> none; {terminal, H} -> H end,
    {ok, #{status => claimed, operation_state => PublicState, ref => Ref,
           request_digest => RequestDigest,
           outcome_ref => OutcomeRef, included => Included, height => Slot,
           receipt_height => ReceiptHeight}};
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
  when Phase =:= pending_vote; Phase =:= voted;
       Phase =:= resolving_commit; Phase =:= resolving_abort;
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
  {aborted, Slot, Reasons, Slots}, Ref)
  when is_integer(Slot), Slot > 0 ->
    case {valid_reasons(abort, Reasons), valid_participant_slots(Slots)} of
        {true, true} ->
            {ok, #{status => aborted, height => Slot, ref => Ref,
                   reasons => Reasons, participant_slots => Slots}};
        _ ->
            {error, outcome_index_corrupt}
    end;
public_group_status(_, _) ->
    {error, outcome_index_corrupt}.

tx_key(#index{anchor = Anchor}, TxId) -> {tx, Anchor, TxId}.
group_key(#index{anchor = Anchor}, GroupId) -> {group, Anchor, GroupId}.
operation_key(#index{anchor = Anchor}, AgentRef, OperationId) ->
    {operation, Anchor, AgentRef, OperationId}.
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
  {operation, Anchor, AgentRef, OperationId},
  #{type := operation,
    ref := {operation, Ns, Anchor, AgentRef, OperationId},
    request_digest := <<_:256>>,
    outcome_ref := OutcomeRef, included := Included,
    first_slot := Slot, state := State} = Row)
  when map_size(Row) =:= 7,
       is_binary(Ns), byte_size(Ns) > 0,
       is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(AgentRef),
       is_binary(OperationId), byte_size(OperationId) =:= 32,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64 ->
    quod_agent_ref:valid_principal({agent, AgentRef}) andalso
        operation_outcome_ref(OutcomeRef) andalso valid_operation_state(State) andalso
        valid_operation_included(OutcomeRef, Included, State);
valid_stored(_Key, _Value) ->
    false.

valid_operation_included({applications, _}, [], unresolved) -> true;
valid_operation_included({applications, Refs}, Included, {terminal, _}) ->
    quod_operation_vector:receipt_references(Included) =:= {ok, Refs};
valid_operation_included({applications, _}, _, _) -> false;
valid_operation_included(_OrdinaryOrGroup, [], _) -> true;
valid_operation_included(_, _, _) -> false.

valid_status(pending) -> true;
valid_status({committed, Slot}) -> is_integer(Slot) andalso Slot > 0;
valid_status({rejected, Reason, Slot}) ->
    is_atom(Reason) andalso is_integer(Slot) andalso Slot > 0;
valid_status(_Status) -> false.

valid_operation_state(unresolved) -> true;
valid_operation_state({terminal, Slot}) ->
    is_integer(Slot) andalso Slot > 0 andalso Slot =< ?MAX_UINT64;
valid_operation_state(_) -> false.

valid_dtx_state(
  #{pending_votes := Pending, projection := Projection,
    applied_floor := Floor} = Dtx, Target)
  when map_size(Dtx) =:= 3,
       is_integer(Floor), Floor >= 0, Floor =< ?MAX_UINT64 ->
    valid_pending_votes(Pending) andalso
        valid_projection(Projection, Target);
valid_dtx_state(_, _) -> false.

valid_pending_votes(Pending) when is_map(Pending) ->
    maps:fold(
      fun(GroupId, {group, _, _, _, _, GroupId} = Ref, true) ->
              ref_identity(Ref) =/= error;
         (_, _, false) -> false
      end, true, Pending);
valid_pending_votes(_) -> false.

valid_group_row(
  #{history := History, ref := Ref, result := Result,
    applied := Applied, terminal := Terminal} = Row,
  GroupId, Anchor)
  when map_size(Row) =:= 5 ->
    valid_history(History, GroupId) andalso
        valid_group_ref(Ref, GroupId, Anchor) andalso
        valid_result_blob(Result) andalso valid_applied(Applied, History) andalso
        valid_terminal(Terminal, History, Applied) andalso
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

valid_applied(none, #{records := Records}) ->
    not maps:is_key(resolve, Records);
valid_applied(#{verdict := Verdict, resolve_ref := Ref, reasons := Reasons,
                manifest_digest := <<_:256>>, plan_digest := PlanDigest,
                slot := Slot, generation := Generation} = Applied, History)
  when map_size(Applied) =:= 7,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation >= 0, Generation =< ?MAX_UINT64 ->
    quod_atomic:history_phase(resolve, History) =:= {ok, Ref} andalso
        ref_slot(Ref) =:= Slot andalso valid_reasons(Verdict, Reasons) andalso
        (is_binary(PlanDigest) andalso byte_size(PlanDigest) =:= 32 orelse
         Verdict =:= abort andalso PlanDigest =:= none);
valid_applied(_, _) -> false.

valid_reasons(commit, none) -> true;
valid_reasons(abort, [_ | _] = Reasons) ->
    case quod_wire_term:encode_failure_reasons(Reasons) of
        {ok, _} -> true;
        _ -> false
    end;
valid_reasons(_, _) -> false.

valid_terminal(none, #{records := Records}, _Applied) ->
    not maps:is_key(complete, Records);
valid_terminal(#{complete_ref := Ref, participant_slots := Slots} = Terminal,
               History, #{resolve_ref := ResolveRef, generation := Generation})
  when map_size(Terminal) =:= 2 ->
    quod_atomic:history_phase(complete, History) =:= {ok, Ref} andalso
        valid_participant_slots(Slots) andalso
        case quod_dtx:certified_ref_binding(ResolveRef) of
            {ok, Target, Slot, _} ->
                lists:keyfind(Target, 1, Slots) =:= {Target, Slot, Generation};
            error -> false
        end;
valid_terminal(_, _, _) -> false.

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

valid_history(#{group_id := GroupId} = History, GroupId) ->
    quod_atomic:valid_group_history(History);
valid_history(_, _) -> false.

valid_projection(
  #{target := Target} = Projection, Target) ->
    quod_atomic:valid_projection(Projection);
valid_projection(_, _) -> false.

valid_identity({Ns, <<_:256>>}) when is_binary(Ns), byte_size(Ns) > 0 -> true;
valid_identity(_) -> false.


ref_slot({quod_dtx_ref, 2, _, _, Slot, _, _, _}) -> Slot.
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
