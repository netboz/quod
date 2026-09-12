-module(quod_dtx_phase_index).
-moduledoc """
Retained exact phase/committee index for verified ledger history.

Live verification and catch-up sometimes need the complete history of an old
`GroupId`, but retaining every group in an Erlang map would make heap use grow
with the ledger.  This library keeps one canonical, bounded history row per
group in a session-unique DETS file instead.  It owns no process and carries no
authority beyond the already-verified ledger stream supplied by its caller.

Catch-up validates a complete ledger window through `preview_batch/4`. Preview
reads the durable scratch rows plus an opaque window delta but does not mutate
DETS. Only after the ledger sink succeeds does `commit_delta/2` install every
changed row with one DETS insert. Startup replay may use `apply_batch/3`;
singleton controls use those same batch APIs rather than separate wrappers.
The hosted Simplex owner retains the mutable table for its whole lifetime.
Its read-only captures pin height and era count; bounded immutable phase
records and append-only committee eras hide subsequent writer advancement.
Foreign-history custody instead suspends/resumes the same table between its
ordered writers. These are distinct lifetimes, not interchangeable handoffs.
The derived file is never repaired or datasync'd; `close/1` deletes it. Startup
cleanup removes only abandoned files of this exact session-file family.
""".

-include("quod_proof_limits.hrl").

-export([open/2, suspend/1, resume/1, close/1, cleanup/2, cleanup/3, stats/1,
         capture/2, is_capture/2, history/2, committee/2, preview_committee/2, preview_histories/2,
         new_delta/0, preview_batch/4, commit_delta/2,
         apply_batch/3]).
-export_type([index/0, delta/0]).

-ifdef(TEST).
-export([test_path/1, test_insert_raw/3]).
-endif.

-define(SCRATCH_PREFIX, <<"dtx-phases.">>).
-define(SCRATCH_SUFFIX, <<".dets">>).
-define(TOKEN_BYTES, 16).
-define(TOKEN_HEX_BYTES, (?TOKEN_BYTES * 2)).
-define(OPEN_ATTEMPTS, 4).
-define(HISTORY_DOMAIN, quod_dtx_phase_history).
-define(HISTORY_VERSION, 1). %% C2: implicit certificates can carry tx14 child blocks
-define(MAX_GROUP_RECORDS, 5).
%% A history stores at most one certified reference for each fixed phase.  A
%% reference combines a body-bounded finality proof with an identity whose
%% namespace is itself bounded by the signed control envelope.  The fixed
%% allowance covers hashes, counters, map/list framing and the ETF header.
-define(MAX_HISTORY_BYTES,
        (?MAX_GROUP_RECORDS *
           (?QUOD_MAX_DTX_BODY_BYTES + ?QUOD_MAX_DTX_CONTROL_BYTES + 512)
         + 4096)).

-record(index, {
          table :: term(),
          path :: file:filename_all(),
          owner :: pid(),
          state = open :: open | suspended | {view, non_neg_integer(), non_neg_integer()}
         }).

-record(delta, {
          rows = #{} :: #{binary() => {quod_dtx:group_history(),
                                       non_neg_integer()}},
          bytes = 0 :: non_neg_integer(),
          eras = #{} :: #{pos_integer() => tuple()}
         }).

-opaque index() :: #index{}.
-opaque delta() :: #delta{}.
-type index_error() ::
        bad_phase_index_argument |
        bad_phase_index_control |
        bad_phase_index_delta |
        phase_index_corrupt |
        {phase_index_io, term()}.

-doc "Open one new session-unique scratch index for a namespace.".
-spec open(file:filename_all(), binary()) ->
          {ok, index()} | {error, index_error()}.
open(LedgerDir, Ns) when is_binary(Ns), byte_size(Ns) > 0 ->
    Dir = quod_ledger_store:ns_dir(LedgerDir, Ns),
    case filelib:ensure_path(Dir) of
        ok -> open_unique(Dir, ?OPEN_ATTEMPTS);
        {error, Reason} -> {error, {phase_index_io, Reason}}
    end;
open(_LedgerDir, _Ns) ->
    {error, bad_phase_index_argument}.

open_unique(_Dir, 0) ->
    {error, {phase_index_io, name_collision}};
open_unique(Dir, Attempts) ->
    Token = binary:encode_hex(crypto:strong_rand_bytes(?TOKEN_BYTES), lowercase),
    Name = <<?SCRATCH_PREFIX/binary, Token/binary, ?SCRATCH_SUFFIX/binary>>,
    Path = filename:join(Dir, binary_to_list(Name)),
    case filelib:is_file(Path) of
        true ->
            open_unique(Dir, Attempts - 1);
        false ->
            open_table(Path, Dir, Attempts)
    end.

open_table(Path, Dir, Attempts) ->
    case dets:open_file(Path, table_options(Path)) of
        {ok, Path} ->
            {ok, #index{table = Path, path = Path, owner = self()}};
        {error, {already_started, _}} ->
            open_unique(Dir, Attempts - 1);
        {error, Reason} ->
            %% Never delete after an open failure: an astronomically unlikely
            %% name race could mean another session now owns this path.
            %% Startup's exact-prefix cleanup reclaims our own abandoned file.
            {error, {phase_index_io, Reason}}
    end.

table_options(Path) ->
    [{file, Path}, {type, set}, {keypos, 1}, {repair, false},
     {auto_save, infinity}].

-doc "Close the table while retaining its session-owned derived rows.".
-spec suspend(index()) -> {ok, index()} | {error, index_error()}.
suspend(Index = #index{table = Table, owner = Owner, state = open}) when Owner =:= self() ->
    case close_table(Table) of
        ok -> {ok, Index#index{state = suspended}};
        {error, Reason} -> {error, {phase_index_io, Reason}}
    end;
suspend(_Index) ->
    {error, bad_phase_index_argument}.

-doc "Reopen this owner's suspended scratch index without repair.".
-spec resume(index()) -> {ok, index()} | {error, index_error()}.
resume(Index = #index{path = Path, state = suspended}) ->
    case filelib:is_file(Path) of
        true ->
            case dets:open_file(Path, table_options(Path)) of
                {ok, Path} -> {ok, Index#index{state = open, owner = self()}};
                {error, Reason} -> {error, {phase_index_io, Reason}}
            end;
        false ->
            {error, {phase_index_io, enoent}}
    end;
resume(_Index) ->
    {error, bad_phase_index_argument}.

-doc "Return constant-work backend extent statistics for attribution.".
-spec stats(index()) ->
          {ok, #{rows := non_neg_integer(), file_bytes := non_neg_integer()}} |
          {error, index_error()}.
stats(#index{table = Table, state = open}) ->
    try {dets:info(Table, size), dets:info(Table, file_size)} of
        {Rows, FileBytes}
          when is_integer(Rows), Rows >= 0,
               is_integer(FileBytes), FileBytes >= 0 ->
            {ok, #{rows => Rows, file_bytes => FileBytes}};
        _ ->
            {error, phase_index_corrupt}
    catch
        Class:Reason -> {error, {phase_index_io, {Class, Reason}}}
    end;
stats(_Index) ->
    {error, bad_phase_index_argument}.

-doc "Close this session's DETS table and remove only its own scratch file.".
-spec close(index()) -> ok | {error, index_error()}.
close(#index{table = Table, path = Path, owner = Owner, state = open}) when Owner =:= self() ->
    CloseResult = close_table(Table),
    DeleteResult = delete_file(Path),
    close_result(CloseResult, DeleteResult);
close(#index{path = Path, state = suspended}) ->
    delete_file(Path);
close(_NotOwned) -> {error, bad_phase_index_argument}.

-doc "Capture an owner-bound read-only index at H with one metadata lookup.".
-spec capture(index(), non_neg_integer()) -> {ok, index()} | {error, index_error()}.
capture(Index = #index{table = Table, owner = Owner, state = open}, Height)
  when Owner =:= self(), is_integer(Height), Height >= 0 ->
    case era_tip(Table) of
        {ok, Count, _Last} -> {ok, Index#index{state = {view, Height, Count}}};
        {error, _} = Error -> Error
    end;
capture(_Index, _Height) -> {error, bad_phase_index_argument}.

-doc "Read one bounded exact group history, excluding records after a captured H.".
-spec history(index(), <<_:256>>) -> {ok, quod_dtx:group_history()} | {error, index_error()}.
history(Index = #index{owner = Owner, state = State}, GroupId)
  when State =/= suspended, is_binary(GroupId), byte_size(GroupId) =:= 32 ->
    case is_process_alive(Owner) of
        true ->
            case load_history(Index, GroupId) of
                {ok, History} -> bounded_history(History, State);
                {error, _} = Error -> Error
            end;
        false -> {error, bad_phase_index_argument}
    end;
history(_Index, _GroupId) -> {error, bad_phase_index_argument}.

bounded_history(History, open) -> {ok, History};
bounded_history(#{group_id := GroupId, records := Records}, {view, Height, _})
  when is_map(Records), map_size(Records) =< ?MAX_GROUP_RECORDS ->
    %% The reducer never overwrites a phase's first exact reference. Filtering
    %% these at-most-five immutable records is MVCC without copying a prefix.
    try maps:filter(fun(_Kind, #{ref := Ref}) ->
            {ok, _Identity, Slot, _Digest} = quod_dtx:certified_ref_binding(Ref),
            Slot =< Height
        end, Records) of
        Kept when map_size(Kept) =:= 0 -> {ok, quod_dtx:initial_group_history()};
        Kept -> {ok, #{group_id => GroupId, records => Kept}}
    catch error:_ -> {error, phase_index_corrupt}
    end;
bounded_history(_History, _View) -> {error, phase_index_corrupt}.

-doc "Check the opaque read-only capture's bound height, without touching storage.".
-spec is_capture(term(), non_neg_integer()) -> boolean().
is_capture(#index{owner = Owner, state = {view, Height, Count}}, Height)
  when is_pid(Owner), is_integer(Height), Height >= 0,
       is_integer(Count), Count >= 0 -> true;
is_capture(_, _) -> false.

-doc "Stage a post-slot committee/route change in the existing window delta.".
-spec preview_committee(delta(), tuple()) -> delta().
preview_committee(Delta = #delta{eras = Eras}, {Start, Committee, <<_:256>>, Routes} = Era)
  when is_integer(Start), Start > 0, is_list(Committee), is_map(Routes) ->
    Delta#delta{eras = Eras#{Start => Era}}.

-doc "Stage the exact histories returned by the shared live-finality reducer.".
-spec preview_histories(delta(), #{binary() => quod_dtx:group_history()}) ->
    {ok, delta()} | {error, index_error()}.
preview_histories(Delta, Histories) when is_map(Histories) ->
    maps:fold(fun(Group, History, {ok, D}) -> stage_history(D, Group, undefined, History);
                 (_Group, _History, {error, _} = Error) -> Error
              end, {ok, Delta}, Histories).

-doc "Indexed post-slot committee lookup bounded by the captured height and era count.".
-spec committee(index(), pos_integer()) -> {ok, tuple()} | not_found | {error, index_error()}.
committee(#index{table = Table, owner = Owner, state = {view, H, Count}}, Slot)
  when is_integer(Slot), Slot > 0, Slot =< H ->
    case is_process_alive(Owner) of
        true -> committee_search(Table, Slot, 1, Count, not_found);
        false -> {error, bad_phase_index_argument}
    end;
committee(_Index, _Slot) -> not_found.

committee_search(_Table, _Slot, Low, High, Best) when Low > High -> Best;
committee_search(Table, Slot, Low, High, Best) ->
    Mid = (Low + High) div 2,
    case dets_lookup(Table, {era, Mid}) of
        {ok, [{{era, Mid}, {Start, _Committee, _Id, _Routes} = Era}]} ->
            case Start =< Slot of
                true -> committee_search(Table, Slot, Mid + 1, High, {ok, Era});
                false -> committee_search(Table, Slot, Low, Mid - 1, Best)
            end;
        {ok, _} -> {error, phase_index_corrupt};
        {error, Reason} -> {error, {phase_index_io, Reason}}
    end.

era_tip(Table) ->
    case dets_lookup(Table, era_tip) of
        {ok, []} -> {ok, 0, none};
        {ok, [{era_tip, Count, Last}]} when is_integer(Count), Count > 0 ->
            {ok, Count, Last};
        {ok, _} -> {error, phase_index_corrupt};
        {error, Reason} -> {error, {phase_index_io, Reason}}
    end.

close_table(Table) ->
    try dets:close(Table) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

delete_file(Path) ->
    case file:delete(Path) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} -> {error, Reason}
    end.

close_result(ok, ok) -> ok;
close_result({error, Reason}, _) -> {error, {phase_index_io, Reason}};
close_result(ok, {error, Reason}) -> {error, {phase_index_io, Reason}}.

-doc "Remove only abandoned files bearing the exact DTX phase-scratch name.".
-spec cleanup(file:filename_all(), binary()) ->
          ok | {error, index_error()}.
cleanup(LedgerDir, Ns) when is_binary(Ns), byte_size(Ns) > 0 ->
    cleanup(LedgerDir, Ns, none);
cleanup(_LedgerDir, _Ns) ->
    {error, bad_phase_index_argument}.

-doc "Sweep abandoned scratch files while preserving the exact handed-off session.".
-spec cleanup(file:filename_all(), binary(), none | index()) ->
          ok | {error, index_error()}.
cleanup(LedgerDir, Ns, Retained) when is_binary(Ns), byte_size(Ns) > 0 ->
    Dir = quod_ledger_store:ns_dir(LedgerDir, Ns),
    case retained_cleanup_path(Dir, Retained) of
        {ok, Keep} ->
            case file:list_dir(Dir) of
                {ok, Names} -> cleanup_names(Dir, Names, Keep);
                {error, enoent} -> ok;
                {error, Reason} -> {error, {phase_index_io, Reason}}
            end;
        error -> {error, bad_phase_index_argument}
    end;
cleanup(_LedgerDir, _Ns, _Retained) ->
    {error, bad_phase_index_argument}.

retained_cleanup_path(_Dir, none) -> {ok, none};
retained_cleanup_path(Dir, #index{path = Path, state = suspended}) ->
    case filename:dirname(Path) =:= Dir of true -> {ok, Path}; false -> error end;
retained_cleanup_path(_Dir, _Retained) -> error.

cleanup_names(_Dir, [], _Keep) -> ok;
cleanup_names(Dir, [Name | Rest], Keep) ->
    Path = filename:join(Dir, Name),
    case is_scratch_name(Name) andalso Path =/= Keep of
        false -> cleanup_names(Dir, Rest, Keep);
        true ->
            case delete_file(Path) of
                ok -> cleanup_names(Dir, Rest, Keep);
                {error, Reason} -> {error, {phase_index_io, Reason}}
            end
    end.

is_scratch_name(Name) ->
    case list_to_binary(Name) of
        <<"dtx-phases.", Token:?TOKEN_HEX_BYTES/binary, ".dets">> ->
            lowercase_hex(Token);
        _ -> false
    end.

lowercase_hex(<<>>) -> true;
lowercase_hex(<<C, Rest/binary>>)
  when (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) ->
    lowercase_hex(Rest);
lowercase_hex(_) -> false.

-doc "Create one empty, bounded catch-up-window delta.".
-spec new_delta() -> delta().
new_delta() -> #delta{}.

-doc "Preview one canonical same-phase control batch without mutating DETS.".
-spec preview_batch(index(), delta(),
                    [{quod_dtx:control(), quod_dtx:certified_ref()}],
                    quod_dtx:projection()) ->
          {ok, delta(), quod_dtx:projection(), list()} |
          {error, term()}.
preview_batch(Index = #index{}, Delta = #delta{}, Controls, Projection)
  when is_list(Controls) ->
    case batch_group_ids(Controls, []) of
        {ok, GroupIds} ->
            case load_batch_histories(Index, Delta, GroupIds, #{}) of
                {ok, Histories0} ->
                    case quod_dtx:reduce_batch(
                           Controls, Histories0, Projection) of
                        {ok, Histories1, Projection1, Items} ->
                            case stage_batch_histories(
                                   Delta, GroupIds, Histories0, Histories1) of
                                {ok, Delta1} ->
                                    {ok, Delta1, Projection1, Items};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        error ->
            {error, bad_phase_index_control}
    end;
preview_batch(_Index, _Delta, _Controls, _Projection) ->
    {error, bad_phase_index_delta}.

batch_group_ids([], Acc) -> {ok, lists:reverse(Acc)};
batch_group_ids([{Control, _Ref} | Rest], Acc) ->
    case control_group_id(Control) of
        {ok, GroupId} -> batch_group_ids(Rest, [GroupId | Acc]);
        error -> error
    end;
batch_group_ids(_, _Acc) -> error.

load_batch_histories(_Index, _Delta, [], Histories) -> {ok, Histories};
load_batch_histories(Index, Delta, [GroupId | Rest], Histories0) ->
    case maps:is_key(GroupId, Histories0) of
        true -> load_batch_histories(Index, Delta, Rest, Histories0);
        false ->
            case delta_history(Index, Delta, GroupId) of
                {ok, History} ->
                    load_batch_histories(
                      Index, Delta, Rest, Histories0#{GroupId => History});
                {error, _} = Error -> Error
            end
    end.

stage_batch_histories(Delta, [], _Histories0, _Histories1) -> {ok, Delta};
stage_batch_histories(Delta0, [GroupId | Rest], Histories0, Histories1) ->
    case stage_history(
           Delta0, GroupId, maps:get(GroupId, Histories0),
           maps:get(GroupId, Histories1)) of
        {ok, Delta1} ->
            stage_batch_histories(Delta1, Rest, Histories0, Histories1);
        {error, _} = Error -> Error
    end.

delta_history(_Index, #delta{rows = Rows}, GroupId)
  when is_map_key(GroupId, Rows) ->
    {History, _Bytes} = maps:get(GroupId, Rows),
    {ok, History};
delta_history(Index, _Delta, GroupId) ->
    history(Index, GroupId).

stage_history(Delta, _GroupId, History, History) ->
    {ok, Delta};
stage_history(#delta{rows = Rows, bytes = Bytes} = Delta,
              GroupId, _OldHistory, History) ->
    Blob = encode_history(History),
    HistoryBytes = byte_size(Blob),
    OldBytes =
        case maps:find(GroupId, Rows) of
            {ok, {_Old, Size}} -> Size;
            error -> 0
        end,
    NewBytes = Bytes - OldBytes + HistoryBytes,
    case HistoryBytes =< ?MAX_HISTORY_BYTES of
        true ->
            {ok, Delta#delta{rows = Rows#{GroupId => {History, HistoryBytes}},
                             bytes = NewBytes}};
        false ->
            {error, bad_phase_index_delta}
    end.

-doc "Install one fully previewed window delta after its ledger sink succeeds.".
-spec commit_delta(index(), delta()) -> ok | {error, index_error()}.
commit_delta(#index{table = Table, owner = Owner, state = open}, #delta{} = Delta)
  when Owner =:= self() ->
    case index_delta_rows(Table, Delta) of
        {ok, []} ->
            ok;
        {ok, Rows} ->
            case dets_insert(Table, Rows) of
                ok -> ok;
                {error, Reason} -> {error, {phase_index_io, Reason}}
            end;
        {error, _} = Error ->
            Error
    end;
commit_delta(_Index, _Delta) ->
    {error, bad_phase_index_delta}.

index_delta_rows(Table, #delta{eras = Eras} = Delta) ->
    case encode_delta(Delta) of
        {ok, Rows} when map_size(Eras) =:= 0 -> {ok, Rows};
        {ok, Rows} ->
            case era_tip(Table) of
                {ok, Count, Last} ->
                    append_era_rows(lists:sort(maps:to_list(Eras)), Count, Last, Rows);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

append_era_rows([], Count, Last, Rows) -> {ok, [{era_tip, Count, Last} | Rows]};
append_era_rows([{_Start, Last} | Rest], Count, Last, Rows) ->
    append_era_rows(Rest, Count, Last, Rows);
append_era_rows([{Start, {Start, _, _, _} = Era} | Rest], Count, Last, Rows)
  when Last =:= none; Start > element(1, Last) ->
    append_era_rows(Rest, Count + 1, Era, [{{era, Count + 1}, Era} | Rows]);
append_era_rows(_Conflicting, _Count, _Last, _Rows) -> {error, bad_phase_index_delta}.

encode_delta(#delta{rows = Rows, bytes = ExpectedBytes})
  when is_map(Rows), is_integer(ExpectedBytes), ExpectedBytes >= 0 ->
    encode_delta_rows(maps:to_list(Rows), 0, ExpectedBytes, []);
encode_delta(_Delta) ->
    {error, bad_phase_index_delta}.

encode_delta_rows([], Bytes, Bytes, Acc) ->
    {ok, lists:reverse(Acc)};
encode_delta_rows(
  [{<<_:256>> = GroupId, {History, StoredBytes}} | Rest],
  Bytes0, ExpectedBytes, Acc)
  when is_integer(StoredBytes), StoredBytes >= 0 ->
    Blob = encode_history(History),
    Bytes = byte_size(Blob),
    Total = Bytes0 + Bytes,
    case Bytes =:= StoredBytes andalso Bytes =< ?MAX_HISTORY_BYTES of
        true ->
            Row = {{group, GroupId}, Blob},
            encode_delta_rows(
              Rest, Total, ExpectedBytes, [Row | Acc]);
        false ->
            {error, bad_phase_index_delta}
    end;
encode_delta_rows(_Malformed, _Bytes, _ExpectedBytes, _Acc) ->
    {error, bad_phase_index_delta}.

-doc "Apply one canonical same-phase control batch with one DETS commit.".
-spec apply_batch(index(),
                  [{quod_dtx:control(), quod_dtx:certified_ref()}],
                  quod_dtx:projection()) ->
          {ok, quod_dtx:projection(), list()} |
          {error, term()}.
apply_batch(Index, Controls, Projection) ->
    case preview_batch(Index, new_delta(), Controls, Projection) of
        {ok, Delta, Projection1, Items} ->
            case commit_delta(Index, Delta) of
                ok -> {ok, Projection1, Items};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

control_group_id(Control) ->
    try
        _ = quod_dtx:control_kind(Control),
        case quod_dtx:group_id(Control) of
            <<_:256>> = GroupId -> {ok, GroupId};
            _ -> error
        end
    catch
        error:function_clause -> error;
        error:{badmatch, _} -> error
    end.

load_history(#index{table = Table}, GroupId) ->
    case dets_lookup(Table, {group, GroupId}) of
        {ok, []} -> {ok, quod_dtx:initial_group_history()};
        {ok, [{{group, GroupId}, Blob}]} -> decode_history(Blob);
        {ok, _Malformed} -> {error, phase_index_corrupt};
        {error, Reason} -> {error, {phase_index_io, Reason}}
    end.

dets_lookup(Table, Key) ->
    try dets:lookup(Table, Key) of
        Rows -> {ok, Rows}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

encode_history(History) ->
    term_to_binary({?HISTORY_DOMAIN, ?HISTORY_VERSION, History}, [deterministic]).

decode_history(Blob) when is_binary(Blob),
                          byte_size(Blob) =< ?MAX_HISTORY_BYTES ->
    case quod_safe_term:decode(Blob, ?MAX_HISTORY_BYTES) of
        {ok, {?HISTORY_DOMAIN, ?HISTORY_VERSION, History}} when is_map(History) ->
            case encode_history(History) =:= Blob of
                true -> {ok, History};
                false -> {error, phase_index_corrupt}
            end;
        _ -> {error, phase_index_corrupt}
    end;
decode_history(_) ->
    {error, phase_index_corrupt}.

dets_insert(Table, Row) ->
    try dets:insert(Table, Row) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

-ifdef(TEST).
test_path(#index{path = Path}) -> Path.

test_insert_raw(#index{table = Table}, <<_:256>> = GroupId, Blob) ->
    dets:insert(Table, {{group, GroupId}, Blob}).
-endif.
