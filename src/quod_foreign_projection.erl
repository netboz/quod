-module(quod_foreign_projection).
-moduledoc """
One unregistered, monitored materialization worker for a followed ontology.

The node-wide `quod_foreign_log` owner supplies only heights already persisted
in its certificate-verified cache.  This worker owns the corresponding Erlog
ETS table and folds those cached entries through `quod_committed_projection`;
it performs no network fetch, certificate verification, effect handling, or
runtime reaction.  Work is one existing foreign-page window per mailbox turn,
so rebuilding a long cached history never monopolizes the foreign-log owner.
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([start_monitor/4, advance/4, stop/1]).

-record(s, {
          owner :: pid(),
          identity :: {binary(), <<_:256>>},
          root :: file:filename_all(),
          cache_ns :: binary(),
          projection :: quod_committed_projection:projection(),
          generation :: reference(),
          target_height = 0 :: non_neg_integer(),
          target_head = none :: none | {non_neg_integer(), <<_:256>>},
          from_height = 0 :: non_neg_integer(),
          changed = [] :: [term()] | resnapshot,
          resnapshot = false :: boolean()
         }).

-spec start_monitor(pid(), {binary(), <<_:256>>}, file:filename_all(), binary()) ->
          {pid(), reference(), reference()}.
start_monitor(Owner, {Ns, <<_:256>> = _Anchor} = Identity, Root, CacheNs)
  when is_pid(Owner), is_binary(Ns), is_binary(CacheNs) ->
    Generation = make_ref(),
    {Pid, MRef} = spawn_monitor(
                    fun() -> init(Owner, Identity, Root, CacheNs, Generation) end),
    {Pid, MRef, Generation}.

-spec advance(pid(), reference(), non_neg_integer(),
              {non_neg_integer(), <<_:256>>}) -> ok.
advance(Pid, Generation, Height, {Height, <<_:256>>} = Head)
  when is_pid(Pid), is_reference(Generation), Height > 0 ->
    Pid ! {advance, Generation, Height, Head},
    ok.

-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    Pid ! stop,
    ok.

init(Owner, {Ns, Anchor} = Identity, Root, CacheNs, Generation) ->
    OwnerMRef = erlang:monitor(process, Owner),
    ProjectionRoot = projection_root(Root, CacheNs, Generation),
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor,
                       #{ledger_dir => ProjectionRoot}),
    Projection = quod_committed_projection:new(
                   Identity, 0, quod_committed_projection:new_est(),
                   Outcomes, none),
    try
        loop(#s{owner = Owner, identity = Identity, root = Root,
                cache_ns = CacheNs, projection = Projection,
                generation = Generation})
    after
        erlang:demonitor(OwnerMRef, [flush]),
        #est{db = #db{ref = Ref}} =
            quod_committed_projection:est(Projection),
        quod_erlog_db_mvcc:delete(Ref),
        ok = quod_outcome:close(
               quod_committed_projection:outcomes(Projection)),
        _ = file:del_dir_r(ProjectionRoot)
    end.

loop(S = #s{generation = Generation}) ->
    receive
        {advance, Generation, Height, Head} ->
            advance_requested(Height, Head, S);
        {advance, _StaleGeneration, _Height, _Head} ->
            loop(S);
        {'DOWN', _MRef, process, Owner, _Reason}
          when Owner =:= S#s.owner ->
            ok;
        stop ->
            ok
    end.

advance_requested(Height, Head,
                  S = #s{projection = Projection, owner = Owner,
                         identity = Identity, generation = Generation}) ->
    Applied = quod_committed_projection:applied(Projection),
    case Height of
        _ when Height < Applied ->
            loop(S);
        _ when Height =:= Applied ->
            publish_ready(Head, S);
        _ ->
            Resnapshot = S#s.resnapshot orelse
                         Height - Applied > ?QUOD_MAX_FOREIGN_PAGE_ENTRIES,
            S1 = S#s{target_height = Height, target_head = Head,
                     from_height = Applied, changed = [],
                     resnapshot = Resnapshot},
            Owner ! {foreign_projection_building, Identity, Generation,
                     Applied},
            materialize_turn(S1)
    end.

materialize_turn(S = #s{identity = {Ns, _Anchor}, root = Root,
                        cache_ns = CacheNs, projection = Projection0,
                        target_height = Target}) ->
    From = quod_committed_projection:applied(Projection0) + 1,
    To = min(Target, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
    case quod_ledger_store:open_ro(CacheNs, Root) of
        {ok, Store} ->
            Result = try quod_ledger_store:read_range(Store, From, To)
                     after quod_ledger_store:close(Store)
                     end,
            case Result of
                {ok, Entries} when length(Entries) =:= To - From + 1 ->
                    case apply_entries(Entries, Projection0, []) of
                        {ok, Projection1, Changed} ->
                            S1 = S#s{projection = Projection1,
                                     changed = merge_changed(
                                                 S#s.changed, Changed)},
                            case quod_committed_projection:applied(Projection1) of
                                Target -> publish_ready(S1#s.target_head, S1);
                                _ -> self() ! {continue, S1#s.generation},
                                     continue_loop(S1)
                            end;
                        {wait, network_identity, Reason, Projection1} ->
                            S#s.owner !
                                {foreign_projection_waiting, S#s.identity,
                                 S#s.generation, Reason,
                                 quod_committed_projection:applied(Projection1)},
                            loop(S#s{projection = Projection1});
                        {error, Reason} ->
                            exit({foreign_projection_invalid_cache, Ns, Reason})
                    end;
                _ ->
                    exit({foreign_projection_cache_gap, Ns, From, To})
            end;
        _ ->
            exit({foreign_projection_cache_unavailable, Ns})
    end.

continue_loop(S = #s{generation = Generation}) ->
    receive
        {continue, Generation} -> materialize_turn(S);
        {advance, Generation, Height, Head} ->
            %% The cache may advance while this generation is rebuilding.
            %% Replace only the target; the already-folded prefix is retained.
            materialize_turn(
              S#s{target_height = max(Height, S#s.target_height),
                  target_head = case Height >= S#s.target_height of
                                    true -> Head;
                                    false -> S#s.target_head
                                end,
                  resnapshot = true});
        {advance, _StaleGeneration, _Height, _Head} ->
            continue_loop(S);
        {'DOWN', _MRef, process, Owner, _Reason}
          when Owner =:= S#s.owner ->
            ok;
        stop -> ok
    end.

apply_entries([], Projection, Changed) ->
    {ok, Projection, Changed};
apply_entries([#entry{index = Index} = Entry | Rest], Projection0, Changed0) ->
    case quod_committed_projection:apply_entry(Entry, Index, Projection0) of
        {ok, Projection1, Result} ->
            apply_entries(Rest, Projection1,
                          merge_changed(Changed0, result_heads(Result)));
        {wait, network_identity, Reason, Projection1} ->
            {wait, network_identity, Reason, Projection1};
        {error, _} = Error ->
            Error
    end.

result_heads(#{kind := content, transactions := Transactions}) ->
    lists:append([maps:get(changed_heads, Tx, []) || Tx <- Transactions]);
result_heads(#{kind := dtx, changed_heads := Heads}) ->
    Heads;
result_heads(_Result) ->
    [].

merge_changed(resnapshot, _Right) -> resnapshot;
merge_changed(_Left, Right) when length(Right) > ?QUOD_MAX_PLAN_DIFF_OPS ->
    resnapshot;
merge_changed(Left, Right) ->
    case bounded_changed(Left, ?QUOD_MAX_PLAN_DIFF_OPS, #{}, []) of
        resnapshot -> resnapshot;
        {Remaining, Seen, Rev} ->
            case bounded_changed(Right, Remaining, Seen, Rev) of
                resnapshot -> resnapshot;
                {_Left, _Seen, Rev1} -> lists:reverse(Rev1)
            end
    end.

bounded_changed([], Left, Seen, Acc) -> {Left, Seen, Acc};
bounded_changed([Head | Rest], Left, Seen, Acc) ->
    case maps:is_key(Head, Seen) of
        true -> bounded_changed(Rest, Left, Seen, Acc);
        false when Left > 0 ->
            bounded_changed(Rest, Left - 1, Seen#{Head => true}, [Head | Acc]);
        false -> resnapshot
    end.

publish_ready({Height, <<_:256>> = Head},
              S = #s{owner = Owner, identity = Identity,
                     generation = Generation, projection = Projection,
                     from_height = From, changed = Changed,
                     resnapshot = Resnapshot0}) ->
    Height = quod_committed_projection:applied(Projection),
    ProjectionId = crypto:hash(
                     sha256,
                     term_to_binary(
                       {quod_foreign_projection, 1, Identity, Height, Head},
                       [deterministic])),
    {Resnapshot, PublishedHeads} =
        case Changed of
            resnapshot -> {true, []};
            _ -> {Resnapshot0, Changed}
        end,
    Owner ! {foreign_projection_ready, Identity, Generation,
             #{from => From, height => Height, projection_id => ProjectionId,
               changed_heads => PublishedHeads, resnapshot => Resnapshot,
               memory_bytes => projection_memory_bytes(Projection)}},
    loop(S#s{changed = [], resnapshot = false, from_height = Height});
publish_ready(_BadHead, S) ->
    loop(S).

projection_memory_bytes(Projection) ->
    #est{db = #db{ref = Ref}} = quod_committed_projection:est(Projection),
    quod_erlog_db_mvcc:memory_words(Ref) * erlang:system_info(wordsize).

projection_root(Root, CacheNs, Generation) ->
    %% Ordinary and distributed outcomes reuse the existing bounded DETS
    %% projection instead of accumulating one unbounded Erlang map per
    %% followed ontology.  The directory is derived and disposable; the
    %% certified history cache remains the only source of truth.
    Suffix = binary_to_list(
               binary:encode_hex(
                 crypto:hash(
                   sha256, term_to_binary(Generation, [deterministic])),
                 lowercase)),
    CacheRoot = quod_ledger_store:ns_dir(
                  filename:join(Root, "projections"), CacheNs),
    filename:join(CacheRoot, Suffix).
