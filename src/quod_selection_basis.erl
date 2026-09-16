-module(quod_selection_basis).
-moduledoc """
Dependencies of one local vote selection, not consensus authority.

An evaluation-owned observation set lasts only for the synchronous check.
Facts are observed by MVCC and flags/native execution by Erlog. Failure,
negation and rollback never erase reads. Only the compact key set survives
on the existing selection row; no KB, process or second cache is retained.
""".
-include_lib("erlog/src/erlog_int.hrl").
-export([capture/2, note/2, affected/2, role_changes/2]).
-ifdef(TEST).
-export([reservation_keys/1]).
-endif.
-export_type([basis/0]).
-type basis() :: #{term() => true}.

-doc "Observe the complete evaluation, disposing its collector on every exit.".
-spec capture(tuple(), fun((tuple()) -> T)) -> {T, basis()}.
capture(Est = #est{db = Db = #db{mod = quod_erlog_db_mvcc, ref = Ref}}, Evaluate) ->
    Observations = ets:new(selection_observations, [set, private]),
    Sink = fun(Event) ->
        true = ets:insert(Observations, [{Key} || Key <- dependency_keys(Event)]), ok
    end,
    Observed = erlog_int:set_observation_sink(Sink,
                 Est#est{db = Db#db{ref = quod_erlog_db_mvcc:observe(Sink, Ref)}}),
    try
        Result = Evaluate(Observed),
        {Result, maps:from_list([{Key, true} || {Key} <- ets:tab2list(Observations)])}
    after ets:delete(Observations) end.

-doc "Record a non-interpreter input at its existing read boundary.".
-spec note(term(), tuple()) -> ok.
note(_, #est{observation_sink = none}) -> ok;
note(Event, #est{observation_sink = Sink}) -> ok = Sink(Event).

dependency_keys({fact, Functor}) -> [{fact, Functor}];
dependency_keys({request, Key}) -> [{request, Key}];
dependency_keys({reservations, Material}) -> reservation_keys(Material);
dependency_keys({flag_value, '$quod_ctx', _EscapedContext}) ->
    %% The raw Prolog flag exposes the whole context, not just whichever
    %% field a later goal happens to inspect. All components are observed.
    [{context, Component} || Component <- [kind, ns, height, subject, chain, id]];
dependency_keys({flag_lookup, Name}) ->
    %% Includes a missing name and enumeration. Unknown flag dependencies
    %% remain parent-bound until a component can be classified soundly.
    [{flag_names, Name}, parent];
dependency_keys({flag_value, Name, _Value}) -> [{flag, Name}, parent];
dependency_keys(_Unclassified) -> [parent].

-doc "Test installed changes; unknown execution always retains the parent fence.".
-spec affected(basis(), basis()) -> boolean().
affected(Basis, Changed) ->
    maps:is_key(parent, Basis) orelse maps:is_key({context, height}, Basis)
      orelse maps:fold(fun(Key, _, Found) -> Found orelse maps:is_key(Key, Changed) end,
                       false, Basis).

-doc "Reservation keys use the authenticated plan's existing conflict descriptor.".
-spec reservation_keys(quod_atomic:admission_material()) -> [term()].
reservation_keys({{quod_dtx_vote, _, _, Target, _, _}, _, #{plans := Plans}}) ->
    case maps:find(Target, Plans) of
        {ok, Plan} ->
            #{reads := Reads, writes := Writes, custody := Custody} =
                maps:get(conflict_descriptor, quod_dtx:core(Plan)),
            [{reservation, F} || F <- ordsets:union(Reads, Writes)] ++
                [{custody, Identity} || Identity <- Custody];
        error -> []
    end.

-doc "Changed reservations from this reducer transition, never a scan of all groups.".
-spec role_changes(quod_atomic:control(), [term()]) -> [term()].
role_changes(Control, Effects) ->
    Acquired = case quod_atomic:control_material(Control) of
        {{quod_dtx_vote, _, _, _, _, prepared}, _, _} = Material -> reservation_keys(Material);
        _ -> []
    end,
    Acquired ++ lists:append([reservation_keys(Own) ||
        {resolved, _, _, Own, _, _} <- Effects, Own =/= none]).
