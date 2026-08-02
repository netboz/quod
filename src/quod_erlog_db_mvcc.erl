-module(quod_erlog_db_mvcc).
-moduledoc """
Shared, versioned erlog database used for committed ontology state.

The ETS table is the only full knowledge-base representation. An erlog state carries
only a `#ref{table,snapshot,pending}` handle, so sending a frozen state to a proof
worker does not copy the knowledge base. Interpreted predicates are versioned by
committed block height; built-ins and compiled predicates are immutable table entries.

Writes are accumulated in the handle's small `pending` map. `commit/3` publishes all
changed predicates at one height in a single engine turn, after which readers opened
at older heights continue resolving the previous versions.
""".

-export([new/1, add_built_in/2, add_compiled_proc/4,
         asserta_clause/4, assertz_clause/4, retract_clause/3, abolish_clauses/2,
         get_procedure/2, get_procedure_type/2, get_interpreted_functors/1]).
-export([commit/3, delete/1, memory_words/1, history_predicates/1]).
-ifdef(TEST).
-export([table/1]).
-endif.

-record(ref, {table    :: ets:tid(),
              snapshot = 0 :: non_neg_integer(),
              pending  = #{} :: map()}).

-type ref() :: #ref{}.
-export_type([ref/0]).

%% erlog database callback -------------------------------------------------

new(_Args) ->
    Table = ets:new(quod_kb, [ordered_set, protected,
                              {read_concurrency, true},
                              {write_concurrency, auto}]),
    #ref{table = Table}.

add_built_in(#ref{table = Table} = Ref, Functor) ->
    true = ets:insert(Table, [{{static, Functor}, built_in},
                              {{functor, Functor}, true}]),
    Ref.

add_compiled_proc(#ref{table = Table} = Ref, Functor, Module, Function) ->
    case raw_procedure(Ref, Functor) of
        built_in -> error;
        _ ->
            true = ets:insert(Table, [{{static, Functor}, {code, {Module, Function}}},
                                      {{functor, Functor}, true}]),
            {ok, Ref}
    end.

asserta_clause(Ref, Functor, Head, Body) ->
    update_clauses(Ref, Functor,
                   fun(Next, Front, Back) ->
                       {{clauses, Next + 1, [{Next, Head, Body} | Front], Back}, ok}
                   end).

assertz_clause(Ref, Functor, Head, Body) ->
    update_clauses(Ref, Functor,
                   fun(Next, Front, Back) ->
                       {{clauses, Next + 1, Front, [{Next, Head, Body} | Back]}, ok}
                   end).

retract_clause(Ref, Functor, Tag) ->
    case raw_procedure(Ref, Functor) of
        built_in -> error;
        {code, _} -> error;
        {clauses, Next, Front, Back} ->
            Clauses = Front ++ lists:reverse(Back),
            {ok, put_pending(Ref, Functor,
                             {clauses, Next, lists:keydelete(Tag, 1, Clauses), []})};
        undefined -> {ok, Ref}
    end.

abolish_clauses(Ref, Functor) ->
    case raw_procedure(Ref, Functor) of
        built_in -> error;
        _ -> {ok, put_pending(Ref, Functor, deleted)}
    end.

get_procedure(Ref, Functor) ->
    case raw_procedure(Ref, Functor) of
        {clauses, _Next, Front, Back} -> {clauses, Front ++ lists:reverse(Back)};
        Other -> Other
    end.

get_procedure_type(Ref, Functor) ->
    case raw_procedure(Ref, Functor) of
        built_in -> built_in;
        {code, _} -> compiled;
        {clauses, _, _, _} -> interpreted;
        undefined -> undefined
    end.

get_interpreted_functors(#ref{table = Table} = Ref) ->
    Functors = ets:select(Table, [{{{functor, '$1'}, '_'}, [], ['$1']}]),
    [Functor || Functor <- Functors,
                get_procedure_type(Ref, Functor) =:= interpreted].

%% snapshot lifecycle -----------------------------------------------------

-spec commit(ref(), non_neg_integer(), non_neg_integer()) -> ref().
commit(#ref{table = Table, snapshot = Previous, pending = Pending} = Ref,
       Version, OldestSnapshot)
  when is_integer(Version), Version >= Previous,
       is_integer(OldestSnapshot), OldestSnapshot =< Version ->
    maps:foreach(
      fun(Functor, Procedure) ->
          true = ets:insert(Table, [{{version, Functor, Version}, Procedure},
                                    {{latest, Functor}, Version},
                                    {{functor, Functor}, true}])
      end, Pending),
    Histories0 = history_index(Table),
    Histories1 = maps:fold(
                   fun(Functor, _Procedure, Acc) ->
                       update_history_index(Table, Functor, Acc)
                   end, Histories0, Pending),
    Histories2 = prune_released_histories(Table, OldestSnapshot, Histories1),
    true = ets:insert(Table, {{meta, histories}, Histories2}),
    Ref#ref{snapshot = Version, pending = #{}}.

-spec delete(ref()) -> ok.
delete(#ref{table = Table}) ->
    try ets:delete(Table), ok catch error:badarg -> ok end.

-ifdef(TEST).
-spec table(ref()) -> ets:tid().
table(#ref{table = Table}) -> Table.
-endif.

-spec memory_words(ref()) -> non_neg_integer().
memory_words(#ref{table = Table}) ->
    try ets:info(Table, memory) catch error:badarg -> 0 end.

%% Predicates are included here only while more than one committed version must
%% remain readable by a proof scope holding an older snapshot.
-spec history_predicates(ref()) -> non_neg_integer().
history_predicates(#ref{table = Table}) ->
    try map_size(history_index(Table)) catch error:badarg -> 0 end.

%% internals --------------------------------------------------------------

update_clauses(Ref, Functor, Update) ->
    case raw_procedure(Ref, Functor) of
        built_in -> error;
        {code, _} -> error;
        {clauses, Next, Front, Back} ->
            {Procedure, ok} = Update(Next, Front, Back),
            {ok, put_pending(Ref, Functor, Procedure)};
        undefined ->
            {Procedure, ok} = Update(0, [], []),
            {ok, put_pending(Ref, Functor, Procedure)}
    end.

put_pending(#ref{pending = Pending} = Ref, Functor, Procedure) ->
    Ref#ref{pending = Pending#{Functor => Procedure}}.

raw_procedure(#ref{pending = Pending} = Ref, Functor) ->
    case maps:find(Functor, Pending) of
        {ok, deleted} -> undefined;
        {ok, Procedure} -> Procedure;
        error -> committed_procedure(Ref, Functor)
    end.

committed_procedure(#ref{table = Table, snapshot = Snapshot}, Functor) ->
    case previous_version(Table, Functor, Snapshot) of
        none -> static_procedure(Table, Functor);
        deleted -> undefined;
        Procedure -> Procedure
    end.

previous_version(Table, Functor, Snapshot) ->
    case ets:prev(Table, {version, Functor, Snapshot + 1}) of
        {version, Functor, Version} = Key when Version =< Snapshot ->
            case ets:lookup(Table, Key) of
                [{_, Procedure}] -> Procedure;
                [] -> none
            end;
        _ -> none
    end.

static_procedure(Table, Functor) ->
    case ets:lookup(Table, {static, Functor}) of
        [{_, Procedure}] -> Procedure;
        [] -> undefined
    end.

%% Keep the newest version at or before the oldest live snapshot, plus every
%% newer version. Older entries can no longer be observed by any worker.
prune_versions(Table, Functor, OldestSnapshot) ->
    case ets:prev(Table, {version, Functor, OldestSnapshot + 1}) of
        {version, Functor, _} = Anchor -> delete_previous(Table, Functor, Anchor);
        _ -> ok
    end.

%% A predicate can stop changing while an old worker still pins several of its
%% versions. Keep a tiny index of only those predicates; when the oldest snapshot
%% advances (including on a no-op block), reclaim their released history without
%% scanning every predicate in the KB on every commit.
prune_released_histories(Table, OldestSnapshot, Histories) ->
    PreviousFloor = case ets:lookup(Table, {meta, gc_floor}) of
                        [{{meta, gc_floor}, Floor}] -> Floor;
                        [] -> -1
                    end,
    case OldestSnapshot > PreviousFloor of
        true ->
            maps:foreach(fun(Functor, _True) ->
                             prune_versions(Table, Functor, OldestSnapshot)
                         end, Histories),
            true = ets:insert(Table, {{meta, gc_floor}, OldestSnapshot}),
            maps:filter(fun(Functor, _True) -> has_history(Table, Functor) end,
                        Histories);
        false -> Histories
    end.

history_index(Table) ->
    case ets:lookup(Table, {meta, histories}) of
        [{{meta, histories}, Histories}] -> Histories;
        [] -> #{}
    end.

update_history_index(Table, Functor, Histories) ->
    case has_history(Table, Functor) of
        true -> Histories#{Functor => true};
        false -> maps:remove(Functor, Histories)
    end.

has_history(Table, Functor) ->
    case ets:lookup(Table, {latest, Functor}) of
        [{{latest, Functor}, Latest}] ->
            case ets:prev(Table, {version, Functor, Latest}) of
                {version, Functor, _} -> true;
                _ -> false
            end;
        [] -> false
    end.

delete_previous(Table, Functor, Key) ->
    case ets:prev(Table, Key) of
        {version, Functor, _} = Previous ->
            true = ets:delete(Table, Previous),
            delete_previous(Table, Functor, Previous);
        _ -> ok
    end.
