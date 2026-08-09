-module(quod_outcome).
-moduledoc """
Rebuildable ordinary-transaction outcome index for one ontology.

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
""".

-include("quod_ledger.hrl").

-export([open/3, close/1,
         admit/2, discard_unsubmitted/2,
         classify/2, terminal/4, flush/1,
         lookup_ref/2, lookup_live/3, public/1]).

-export_type([index/0, outcome/0]).

-define(FORMAT, 3).
-define(CACHE_LIMIT, 4096).

-record(index, {
          ns :: binary(),
          anchor :: binary(),
          backend :: {dets, term()} | {memory, map()},
          cache = #{} :: map(),
          order = gb_trees:empty() :: gb_trees:tree(),
          clock = 0 :: non_neg_integer(),
          staged = #{} :: map()
         }).

-opaque index() :: #index{}.
-type outcome() ::
        #{ref := {transaction, binary(), binary(), binary()},
          tx_id := binary(), plan_digest := binary(),
          status := pending | {committed, pos_integer()} |
                    {rejected, atom(), pos_integer()}}.
-type index_error() :: outcome_index_bad_transaction |
                       outcome_index_conflict |
                       {outcome_index_io, term()}.

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
            {ok, #index{ns = Ns, anchor = Anchor,
                        backend = {memory, #{}}}}
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
            case dets_write(Name, {meta, ?FORMAT, Anchor}) of
                ok -> {ok, disk_index(Ns, Anchor, Name)};
                {error, Reason} -> reset_open_table(
                                     Ns, Anchor, Name, Path, MayReset, Reason)
            end;
        [{meta, ?FORMAT, Anchor}] ->
            {ok, disk_index(Ns, Anchor, Name)};
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

disk_index(Ns, Anchor, Name) ->
    #index{ns = Ns, anchor = Anchor, backend = {dets, Name}}.

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

-doc "Look up an anchored transaction reference through the owner-held index.".
-spec lookup_ref(index(), term()) ->
          {{ok, outcome()} | {error, index_error()} |
           not_found | wrong_anchor, index()}.
lookup_ref(Index = #index{ns = Ns, anchor = Anchor},
           {transaction, Ns, Anchor, <<_:256>> = TxId}) ->
    lookup_tx(Index, TxId);
lookup_ref(Index = #index{ns = Ns},
           {transaction, Ns, <<_:256>>, <<_:256>>}) ->
    {wrong_anchor, Index};
lookup_ref(Index, _Ref) ->
    {not_found, Index}.

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
public(_Other) ->
    {error, outcome_index_corrupt}.

public_status(pending) -> {ok, #{status => pending}};
public_status({committed, Slot}) when is_integer(Slot), Slot > 0 ->
    {ok, #{status => committed, height => Slot}};
public_status({rejected, Reason, Slot})
  when is_atom(Reason), is_integer(Slot), Slot > 0 ->
    {ok, #{status => rejected, reason => Reason, height => Slot}};
public_status(_Other) -> error.

tx_key(#index{anchor = Anchor}, TxId) -> {tx, Anchor, TxId}.

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
valid_stored(_Key, _Value) ->
    false.

valid_status(pending) -> true;
valid_status({committed, Slot}) -> is_integer(Slot) andalso Slot > 0;
valid_status({rejected, Reason, Slot}) ->
    is_atom(Reason) andalso is_integer(Slot) andalso Slot > 0;
valid_status(_Status) -> false.

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
        ok -> {ok, Index#index{staged = #{}}};
        {error, Reason} -> invalidate_backend(Name, Reason)
    end;
flush(Index = #index{backend = {memory, Map}, staged = Staged}) ->
    {ok, Index#index{backend = {memory, maps:merge(Map, Staged)},
                     staged = #{}}}.

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
