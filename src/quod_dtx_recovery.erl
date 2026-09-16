-module(quod_dtx_recovery).
-moduledoc """
Pure Vote/Resolve/Complete planner, executed by the existing coordinator.

The local role supplies its already-authenticated own row. Foreign evidence
enters only after the shared history verifier has checked finality and
authorship. The snapshot keeps compact certified facts, not foreign plans,
signatures to recheck, mutable custody, or a second outcome authority.

An absence is a volatile observation permitting an exact presentation or
submission. It never decides an outcome. The executor consumes it once,
parks uncertainty, and invalidates it on a real progress/reconnect edge.
There is no clock, timer, polling loop or process in this module.

Only O constructs Resolve and Complete. A non-origin role, started by the
existing owner's any-vote/deadline predicate, may query and present to O only.
Seeing O's vote parks that same worker until the owner's own Resolve retires
it. Restart reconstructs the duty from the own committed row.

Client success still waits for participant application. O's exact Resolve
evidence must come from its owned committed view; Simplex sends the terminal
notification on the same ordered Prolog apply channel. This preserves the
existing source apply-before-result boundary without a second local collector.
""".

-export([empty/0, observe/3, absent/3, attempted/3, progress/2, applied/4, next/2, terminal/2]).
-export_type([snapshot/0, phase_evidence/0, applied_evidence/0, command/0, command_batch/0]).

-type identity() :: {binary(), <<_:256>>}.
-type ref() :: quod_dtx:certified_ref().
-type own_row() :: #{material := quod_atomic:admission_material(),
                     ref := none | ref(), resolution := none | map()}.
-type phase_evidence() :: {identity(), quod_atomic:control(), ref()}.
-type applied_evidence() :: {identity(), quod_applied_certificate:applied_certificate()}.
-opaque snapshot() :: #{evidence := map(), absent := map(), applied := map()}.
-type command() ::
    {submit, identity(), quod_atomic:record()} |
    {present, identity(), quod_atomic:group()} |
    {phase, identity(), <<_:256>>, vote | resolve} |
    {applied, identity(), <<_:256>>, ref(), non_neg_integer(), commit | abort}.
-type command_batch() ::
    {ordered | independent, vote | resolve | applied | complete, [command()]}.

-doc "An empty, bounded observation snapshot; it owns no durable obligation.".
-spec empty() -> snapshot().
empty() -> #{evidence => #{}, absent => #{}, applied => #{}}.

-doc """
Install one already-verified phase, retaining only its exact reference and
planning facts. Foreign plans and entry artifacts do not enter this snapshot.
Different quorum subsets for the same claim preserve the first observation.
""".
-spec observe(own_row(), phase_evidence(), snapshot()) ->
          {ok, snapshot()} | {error, invalid_phase_evidence | conflicting_phase_evidence}.
observe(Own, {Target, Control, Ref}, Snapshot) ->
    Binding = binding(Own),
    Kind = quod_atomic:control_kind(Control),
    case quod_atomic:control_target(Control) =:= Target
         andalso quod_atomic:group_id(Control) =:= maps:get(group_id, Binding)
         andalso allowed(Kind, Target, Binding)
         andalso exact_ref(Target, quod_atomic:record_digest(Control), Ref) of
        true -> put_fact({Kind, Target}, fact(quod_atomic:control_material(Control), Ref), Snapshot);
        false -> {error, invalid_phase_evidence}
    end.

allowed(complete, Target, #{origin := Origin}) -> Target =:= Origin;
allowed(Kind, Target, #{participants := Roles}) when Kind =:= vote; Kind =:= resolve ->
    lists:keymember(Target, 1, Roles);
allowed(_, _, _) -> false.

exact_ref(Target, Digest, Ref) ->
    case quod_dtx:certified_ref_binding(Ref) of
        {ok, Target, _, Digest} -> true;
        _ -> false
    end.

fact({{quod_dtx_vote, 4, _, Target, _, Choice}, _, #{plans := Plans}}, Ref) ->
    Generation = case maps:find(Target, Plans) of
        {ok, Plan} -> quod_dtx:overlay_generation(Plan);
        error -> 0
    end,
    #{ref => Ref, choice => Choice, generation => Generation};
fact({{quod_dtx_resolve, 4, _, _, _, Outcome, _, _, OwnVote, Generation, _}, _, _}, Ref) ->
    #{ref => Ref, outcome => Outcome, own_vote => OwnVote, generation => Generation};
fact({{quod_dtx_complete, 4, _, _, _, _, _, _}, _, _}, Ref) -> #{ref => Ref}.

put_fact(Key, Fact, Snapshot = #{evidence := Evidence, absent := Absent}) ->
    case maps:find(Key, Evidence) of
        error ->
            {ok, Snapshot#{evidence := Evidence#{Key => Fact}, absent := maps:remove(Key, Absent)}};
        {ok, Old} ->
            case maps:remove(ref, Fact) =:= maps:remove(ref, Old) andalso
                 quod_dtx:same_certified_ref(maps:get(ref, Fact), maps:get(ref, Old)) of
                true -> {ok, Snapshot};
                false -> {error, conflicting_phase_evidence}
            end
    end.

-doc "Record authoritative absence, without replacing any certified observation.".
-spec absent(identity(), vote | resolve | complete, snapshot()) -> snapshot().
absent(Target, Kind, Snapshot = #{evidence := Evidence, absent := Absent}) ->
    Key = {Kind, Target},
    case maps:is_key(Key, Evidence) of
        true -> Snapshot;
        false -> Snapshot#{absent := Absent#{Key => maps:get(Key, Absent, true)}}
    end.

-doc "Consume a delivery allowance; absence alone cannot authorize another attempt.".
-spec attempted(identity(), vote | resolve | complete, snapshot()) -> snapshot().
attempted(Target, Kind, Snapshot = #{absent := Absent}) ->
    Snapshot#{absent := Absent#{{Kind, Target} => consumed}}.

-doc "Forget only a target's volatile absences after an actual progress or reconnect edge.".
-spec progress(identity(), snapshot()) -> snapshot().
progress(Target, Snapshot = #{absent := Absent}) ->
    Snapshot#{absent := maps:filter(fun({_, T}, _) -> T =/= Target end, Absent)}.

-doc "Bind an already-verified AM3 result to its exact target Resolve; no second signature walk.".
-spec applied(own_row(), identity(), quod_applied_certificate:applied_certificate(), snapshot()) ->
          {ok, snapshot()} | {error, invalid_applied_evidence}.
applied(Own, Target, Certificate, Snapshot = #{evidence := Evidence, applied := Applied}) ->
    #{group_id := GroupId, origin := Origin} = binding(Own),
    case {Target =/= Origin, maps:find({resolve, Target}, Evidence),
          quod_applied_certificate:applied_certificate_binding(Certificate)} of
        {true, {ok, #{ref := Ref, generation := Generation, outcome := Outcome, own_vote := OwnVote}},
         {ok, #{target := Target, group_id := GroupId, generation := Generation,
                verdict := Outcome, resolve_ref := CertifiedRef}}} when OwnVote =/= none ->
            case quod_dtx:same_certified_ref(Ref, CertifiedRef) of
                true -> {ok, Snapshot#{applied := Applied#{Target => Certificate}}};
                false -> {error, invalid_applied_evidence}
            end;
        _ -> {error, invalid_applied_evidence}
    end.

-doc "Plan the next message-driven wave, wait, or return the certified Complete.".
-spec next(own_row(), snapshot()) -> wait | {ok, command_batch()} | {done, ref()} | {error, term()}.
next(Own, Snapshot) ->
    case plan(Own, Snapshot) of
        {ok, {Mode, Stage, Commands}} ->
            %% One allowance per exact target/phase. Both ordinary delivery
            %% and takeover presentation use it; neither absence nor a local
            %% re-plan manufactures a second send without actual progress.
            batch(Mode, Stage, [C || C <- Commands, delivery_allowed(C, Snapshot)]);
        Result -> Result
    end.

delivery_allowed({submit, T, Record}, #{absent := Absent}) ->
    maps:get({quod_atomic:record_kind(Record), T}, Absent, false) =/= consumed;
delivery_allowed({present, T, _Group}, #{absent := Absent}) ->
    maps:get({vote, T}, Absent, false) =/= consumed;
delivery_allowed(_, _) -> true.

plan(Own, Snapshot) ->
    #{origin := Origin, group_id := Id} = Binding = binding(Own),
    Target = own_target(Own),
    case seed_own(Own, Snapshot) of
        {ok, Seeded} when Target =/= Origin -> participant(Binding, Seeded);
        {ok, Seeded = #{evidence := Evidence}} ->
            case maps:find({complete, Origin}, Evidence) of
                {ok, #{ref := Ref}} -> {done, Ref};
                error -> source(Own, Binding, Seeded)
            end;
        {error, Reason} -> {error, {invalid_own_vote, Id, Reason}}
    end.

binding(#{material := {_, _, #{group := Binding}}}) -> Binding.
own_target(#{material := {{quod_dtx_vote, 4, _, Target, _, _}, _, _}}) -> Target.

seed_own(#{ref := none}, Snapshot) -> {ok, Snapshot};
seed_own(#{material := Material, ref := Ref} = Own, Snapshot) ->
    put_fact({vote, own_target(Own)}, fact(Material, Ref), Snapshot).

participant(#{origin := Origin, group_id := Id, group := Group}, Snapshot) ->
    case observation(vote, Origin, Snapshot) of
        unknown -> batch(ordered, vote, [{phase, Origin, Id, vote}]);
        absent -> batch(ordered, vote, [{present, Origin, Group}]);
        #{ref := _} -> wait
    end.

source(Own, #{origin := Origin, group_id := Id} = Binding, Snapshot) ->
    case observation(vote, Origin, Snapshot) of
        unknown -> batch(ordered, vote, [{phase, Origin, Id, vote}]);
        absent ->
            #{material := {Vote, _, _}} = Own,
            batch(ordered, vote, [{submit, Origin, Vote}]);
        #{ref := OriginRef} -> source_votes(Binding, OriginRef, Snapshot)
    end.

source_votes(#{participants := Roles, group_id := Id, group := Group} = Binding,
             OriginRef, Snapshot) ->
    Votes = [{T, observation(vote, T, Snapshot)} || {T, _} <- Roles],
    Unknown = [{phase, T, Id, vote} || {T, unknown} <- Votes],
    case Unknown of
        [_ | _] -> batch(independent, vote, Unknown);
        [] ->
            case outcome(Votes) of
                pending ->
                    %% Presentation is O-only. Missing targets use ordinary
                    %% Vote admission: no bundle, no positive vote, and no
                    %% refusal until that target validates the bound deadline.
                    Commands = [begin
                        {ok, Vote} = quod_atomic:new_vote(Group, T, none, {refused, [vote_deadline]}),
                        {submit, T, Vote}
                    end || {T, absent} <- Votes],
                    batch(independent, vote, Commands);
                {Outcome, Proof, Reasons} ->
                    source_resolves(Binding, OriginRef, Votes, Outcome, Proof, Reasons, Snapshot)
            end
    end.

%% Only certified votes choose an outcome. A refused endpoint response, a
%% deadline notification or an authoritative absence cannot enter this fold.
outcome(Votes) ->
    case [{Ref, Blob} || {_, #{ref := Ref, choice := {refused, Blob}}} <- Votes] of
        [{Ref, Blob} | _] ->
            {ok, Reasons} = quod_wire_term:decode_failure_reasons(Blob),
            {abort, {refused, Ref}, Reasons};
        [] ->
            case lists:all(fun({_, V}) -> is_map(V) end, Votes) of
                true -> {commit, {all_prepared, [{T, maps:get(ref, V)} || {T, V} <- Votes]}, none};
                false -> pending
            end
    end.

source_resolves(#{participants := Roles, group_id := Id, group := Group} = Binding,
                OriginRef, Votes, Outcome, Proof, Reasons, Snapshot) ->
    Resolves = [{T, observation(resolve, T, Snapshot)} || {T, _} <- Roles],
    case [{phase, T, Id, resolve} || {T, unknown} <- Resolves] of
        [_ | _] = Unknown -> batch(independent, resolve, Unknown);
        [] ->
            case resolve_commands(Resolves, maps:from_list(Votes), Group, OriginRef,
                                  {Outcome, Proof, Reasons}, []) of
                {ok, []} -> source_applied(Binding, Resolves, Outcome, Snapshot);
                {ok, Commands} -> batch(independent, resolve, Commands);
                {error, _} = Error -> Error
            end
    end.

resolve_commands([], _, _, _, _, Acc) -> {ok, lists:reverse(Acc)};
resolve_commands([{T, absent} | Rest], Votes, Group, OriginRef,
                  {Outcome, Proof, Reasons} = Result, Acc) ->
    {OwnVote, Generation} = resolve_generation(maps:get(T, Votes), Outcome),
    OutcomeClaim = case Outcome of commit -> commit; abort -> {abort, Reasons} end,
    case quod_atomic:new_resolve(Group, OriginRef, T, OutcomeClaim, Proof, OwnVote, Generation) of
        {ok, Record} ->
            resolve_commands(Rest, Votes, Group, OriginRef, Result, [{submit, T, Record} | Acc]);
        {error, Reason} -> {error, {resolve_construction, Reason}}
    end;
resolve_commands([{_, #{outcome := Outcome}} | Rest], Votes, Group, OriginRef,
                  {Outcome, _, _} = Result, Acc) ->
    resolve_commands(Rest, Votes, Group, OriginRef, Result, Acc);
resolve_commands(_, _, _, _, _, _) -> {error, conflicting_resolve_outcome}.

resolve_generation(absent, abort) -> {none, 0};
resolve_generation(#{ref := Ref, generation := Generation}, commit) -> {Ref, Generation + 1};
resolve_generation(#{ref := Ref, generation := Generation}, abort) -> {Ref, Generation}.

source_applied(#{origin := Origin, group_id := Id, group := Group}, Resolves,
               Outcome, #{applied := Applied}) ->
    Missing = [{applied, T, Id, Ref, Generation, Outcome}
               || {T, #{ref := Ref, generation := Generation, own_vote := OwnVote}} <- Resolves,
                  T =/= Origin, OwnVote =/= none, not maps:is_key(T, Applied)],
    case Missing of
        [_ | _] -> batch(independent, applied, Missing);
        [] ->
            Rows = [{T, maps:get(ref, R), maps:get(generation, R)} || {T, R} <- Resolves],
            case quod_atomic:new_complete(Group, Outcome, Rows, lists:sort(maps:to_list(Applied))) of
                {ok, Complete} -> batch(ordered, complete, [{submit, Origin, Complete}]);
                {error, Reason} -> {error, {complete_construction, Reason}}
            end
    end.

observation(Kind, Target, #{evidence := Evidence, absent := Absent}) ->
    Key = {Kind, Target},
    case maps:find(Key, Evidence) of
        {ok, Fact} -> Fact;
        error -> case maps:get(Key, Absent, false) of
            true -> absent;
            consumed -> absent;
            false -> unknown
        end
    end.

batch(_, _, []) -> wait;
batch(Mode, Stage, Commands) -> {ok, {Mode, Stage, Commands}}.

-doc """
Return the complete applied vector before asynchronous Complete bookkeeping.
Source height is its Resolve slot, identical to stored outcomes. The executor
must verify source evidence through the owned view and publish on Simplex's
ordered apply channel, never directly from this child to Prolog.
""".
-spec terminal(own_row(), snapshot()) -> pending | {ok, map()} | {error, term()}.
terminal(Own, Snapshot = #{absent := Absent}) ->
    #{origin := Source} = binding(Own),
    %% Complete delivery is asynchronous cleanup, not part of client finality.
    ReadyView = Snapshot#{absent := maps:remove({complete, Source}, Absent)},
    case next(Own, ReadyView) of
        {ok, {ordered, complete, [{submit, Origin,
          {quod_dtx_complete, 4, _, Origin, _, Outcome, Rows, _}}]}} ->
            {ok, Seeded} = seed_own(Own, Snapshot),
            #{participants := Roles} = binding(Own),
            {Outcome, _, Reasons} = outcome([{T, observation(vote, T, Seeded)} || {T, _} <- Roles]),
            Slots = [begin
                {ok, T, Slot, _} = quod_dtx:certified_ref_binding(Ref),
                {T, Slot, Generation}
            end || {T, Ref, Generation} <- Rows],
            {Origin, SourceSlot, _} = lists:keyfind(Origin, 1, Slots),
            {ok, #{verdict => Outcome, reasons => Reasons, source_slot => SourceSlot,
                   participant_slots => Slots}};
        {error, _} = Error -> Error;
        _ -> pending
    end.
