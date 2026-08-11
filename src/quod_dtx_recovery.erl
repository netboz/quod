-module(quod_dtx_recovery).
-moduledoc """
Pure coordinator recovery planner for one durable distributed transaction.

The planner owns no process, timer, transport, signature lane, or durable
state. Every call reconstructs its answer from the canonical Begin and a
bounded snapshot of already-verified phase evidence. The embedding coordinator
executes the returned commands, verifies resulting certified phase references
through `quod_foreign_log`, corroborates prepared-Finalize application through
`quod_dtx_current_view`, and calls `next/2` again.

`evidence` rows are exact `{TargetIdentity, Control, CertifiedRef}` triples.
They are ordered by Begin, target-ordered Prepares, Decision, target-ordered
Finalizes, and Complete.  This module rechecks each control signature, target,
group and semantic digest against its certified reference; foreign committee
and finality verification remains the caller's responsibility.

`generations` are target-ordered post-Prepare generations obtained from
verified Prepare evidence.  For a direct abort they are the target's current
generation hint from the DTX endpoint.  `applied` rows are target-ordered,
already-authenticated and committee-corroborated status bodies; this module
checks their exact Finalize/generation/verdict binding.  A certified direct
abort needs no such row because its Finalize reference is itself the applied
no-op proof.

`refusal` is either `none` or the exact target, Prepare semantic digest,
generation, and canonical atom-safe failure-stack blob returned by a
deterministic endpoint refusal.  The planner rechecks every binding and copies
the decoded stack unchanged into Decision(abort); transport and readiness
errors are not refusals.

Commands are returned in bounded canonical target order.  Reissuing a command
before new evidence arrives is deliberate: semantic DTX records are
idempotent, while the embedding engine owns request correlation and retry
timing.
""".

-include("quod_proof_limits.hrl").

-export([empty/0, next/2]).
-export_type([snapshot/0, phase_evidence/0, applied_evidence/0, command/0]).

-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(MAX_PHASE_EVIDENCE, (2 * ?QUOD_MAX_DTX_PARTICIPANTS + 3)).

-type identity() :: {binary(), <<_:256>>}.
-type verdict() :: commit | abort.
-type phase_evidence() ::
        {identity(), quod_dtx:control(), quod_dtx:certified_ref()}.
-type applied_evidence() ::
        {identity(), <<_:256>>, <<_:256>>, quod_dtx:certified_ref(),
         non_neg_integer(), verdict()}.
-type snapshot() ::
        #{evidence := [phase_evidence()],
          generations := [{identity(), non_neg_integer()}],
          applied := [applied_evidence()],
          refusal := none |
              {identity(), <<_:256>>, non_neg_integer(), binary()}}.
-type command() ::
        {submit, identity(), quod_dtx:control_record()} |
        {phase, identity(), <<_:256>>, prepare} |
        {applied, identity(), <<_:256>>, quod_dtx:certified_ref(),
         non_neg_integer(), verdict()}.
-doc "An empty volatile observation snapshot for a newly journaled Begin.".
-spec empty() -> snapshot().
empty() ->
    #{evidence => [], generations => [], applied => [], refusal => none}.

-doc """
Return the next non-empty bounded command batch, or the certified Complete.

The Begin is the canonical semantic record retained by the signing journal;
no signed outer envelope is retained or manufactured here.
""".
-spec next(quod_dtx:control_record(), snapshot()) ->
          {ok, [command()]} |
          {done, quod_dtx:certified_ref()} |
          {error, term()}.
next(Begin, Snapshot) ->
    case recovery_context(Begin) of
        {ok, Context} -> next_snapshot(Begin, Snapshot, Context);
        error -> {error, invalid_begin}
    end.

recovery_context(Begin) ->
    case quod_dtx:begin_recovery_rows(Begin) of
        {ok, Origin, GroupId, Rows} ->
            Targets = [Target || {Target, _PlanBlob} <- Rows],
            {ok, #{origin => Origin, group_id => GroupId,
                   rows => Rows, targets => Targets,
                   plans => maps:from_list(Rows)}};
        error ->
            error
    end.

next_snapshot(Begin,
              #{evidence := Evidence, generations := Generations,
                applied := Applied, refusal := Refusal} = Snapshot,
              Context)
  when map_size(Snapshot) =:= 4 ->
    case index_generations(Generations, Context) of
        {ok, GenerationMap} ->
            case index_evidence(Evidence, Context) of
                {ok, Index} ->
                    case validate_chain(Begin, Index, GenerationMap, Context) of
                        ok ->
                            case index_applied(Applied, Index, Context) of
                                {ok, AppliedMap} ->
                                    case validate_refusal(
                                           Refusal, Index, GenerationMap,
                                           Context) of
                                        {ok, ValidRefusal} ->
                                            drive(Begin, Index, GenerationMap,
                                                  AppliedMap, ValidRefusal,
                                                  Context);
                                        error -> {error, invalid_refusal}
                                    end;
                                error -> {error, invalid_applied_evidence}
                            end;
                        {error, _} = Error -> Error
                    end;
                error -> {error, invalid_phase_evidence}
            end;
        error -> {error, invalid_generations}
    end;
next_snapshot(_Begin, _Snapshot, _Context) ->
    {error, invalid_snapshot}.

%% ===================================================================
%% Canonical bounded input indexing
%% ===================================================================

empty_index() ->
    #{'begin' => none, prepares => #{}, decision => none,
      finalizes => #{}, complete => none}.

index_evidence(Evidence, Context) ->
    index_evidence(Evidence, none, 0, Context, empty_index()).

index_evidence([], _Previous, _Count, _Context, Index) ->
    {ok, Index};
index_evidence([Row | Rest], Previous, Count, Context, Index)
  when Count < ?MAX_PHASE_EVIDENCE ->
    case evidence_row(Row, Context) of
        {ok, Key, Kind, Target, Entry}
          when Previous =:= none; Previous < Key ->
            case put_evidence(Kind, Target, Entry, Index) of
                {ok, Index1} ->
                    index_evidence(
                      Rest, Key, Count + 1, Context, Index1);
                error -> error
            end;
        _ -> error
    end;
index_evidence(_, _Previous, _Count, _Context, _Index) ->
    error.

evidence_row({Target, Control, Ref}, Context) ->
    try
        Kind = quod_dtx:control_kind(Control),
        GroupId = maps:get(group_id, Context),
        Digest = quod_dtx:record_digest(Control),
        Checks =
            quod_dtx:control_target(Control) =:= Target andalso
            quod_dtx:verify_control(Target, Control) andalso
            quod_dtx:group_id(Control) =:= GroupId andalso
            phase_target_allowed(Kind, Target, Context),
        case {Checks, quod_dtx:certified_ref_binding(Ref)} of
            {true, {ok, Target, Slot, Digest}} ->
                {ok, {phase_rank(Kind), Target}, Kind, Target,
                 #{control => Control, ref => Ref, slot => Slot}};
            _ ->
                error
        end
    catch
        _:_ -> error
    end;
evidence_row(_, _Context) ->
    error.

phase_rank('begin') -> 1;
phase_rank(prepare) -> 2;
phase_rank(decision) -> 3;
phase_rank(finalize) -> 4;
phase_rank(complete) -> 5.

phase_target_allowed('begin', Target, #{origin := Target}) -> true;
phase_target_allowed(decision, Target, #{origin := Target}) -> true;
phase_target_allowed(complete, Target, #{origin := Target}) -> true;
phase_target_allowed(prepare, Target, Context) -> participant(Target, Context);
phase_target_allowed(finalize, Target, Context) -> participant(Target, Context);
phase_target_allowed(_, _, _) -> false.

participant(Target, #{plans := Plans}) -> maps:is_key(Target, Plans).

put_evidence('begin', _Target, Entry, #{'begin' := none} = Index) ->
    {ok, Index#{'begin' := Entry}};
put_evidence(decision, _Target, Entry, #{decision := none} = Index) ->
    {ok, Index#{decision := Entry}};
put_evidence(complete, _Target, Entry, #{complete := none} = Index) ->
    {ok, Index#{complete := Entry}};
put_evidence(prepare, Target, Entry, #{prepares := Rows} = Index)
  when not is_map_key(Target, Rows) ->
    {ok, Index#{prepares := Rows#{Target => Entry}}};
put_evidence(finalize, Target, Entry, #{finalizes := Rows} = Index)
  when not is_map_key(Target, Rows) ->
    {ok, Index#{finalizes := Rows#{Target => Entry}}};
put_evidence(_, _, _, _) ->
    error.

index_generations(Rows, Context) ->
    index_generations(Rows, none, 0, Context, #{}).

index_generations([], _Previous, _Count, _Context, Acc) ->
    {ok, Acc};
index_generations([{Target, Generation} | Rest], Previous, Count,
                  Context, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       (Previous =:= none orelse Previous < Target),
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    case participant(Target, Context) of
        true ->
            index_generations(
              Rest, Target, Count + 1, Context,
              Acc#{Target => Generation});
        false -> error
    end;
index_generations(_, _Previous, _Count, _Context, _Acc) ->
    error.

index_applied(Rows, Index, Context) ->
    index_applied(Rows, none, 0, Index, Context, #{}).

index_applied([], _Previous, _Count, _Index, _Context, Acc) ->
    {ok, Acc};
index_applied(
  [{Target, CommitteeId, GroupId, FinalizeRef, Generation, Verdict} = Row
   | Rest], Previous, Count, Index, Context, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       (Previous =:= none orelse Previous < Target),
       is_binary(CommitteeId), byte_size(CommitteeId) =:= 32,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64,
       (Verdict =:= commit orelse Verdict =:= abort) ->
    case applied_matches_finalize(
           Target, GroupId, FinalizeRef, Generation, Verdict,
           Index, Context) of
        true ->
            index_applied(
              Rest, Target, Count + 1, Index, Context, Acc#{Target => Row});
        false -> error
    end;
index_applied(_, _Previous, _Count, _Index, _Context, _Acc) ->
    error.

applied_matches_finalize(Target, GroupId, FinalizeRef, Generation, Verdict,
                         #{finalizes := Finalizes},
                         #{group_id := GroupId}) ->
    case maps:get(Target, Finalizes, none) of
        #{control := Control, ref := FinalizeRef} ->
            case quod_dtx:recovery_phase(quod_dtx:control_body(Control)) of
                {ok, #{kind := finalize, verdict := Verdict,
                       prepare_ref := PrepareRef,
                       generation := Generation}} ->
                    PrepareRef =/= none;
                _ -> false
            end;
        none -> false
    end;
applied_matches_finalize(_, _, _, _, _, _, _) ->
    false.

validate_refusal(none, _Index, _Generations, _Context) ->
    {ok, none};
validate_refusal(
  {Target, SemanticDigest, Generation, ReasonsBlob},
  #{'begin' := BeginEntry, prepares := Prepares}, Generations,
  #{plans := Plans} = Context)
  when BeginEntry =/= none, is_binary(SemanticDigest),
       is_integer(Generation), Generation >= 0, Generation =< ?MAX_UINT64,
       is_binary(ReasonsBlob) ->
    case {participant(Target, Context), maps:is_key(Target, Prepares),
          maps:find(Target, Generations), maps:find(Target, Plans),
          decode_refusal_reasons(Target, ReasonsBlob)} of
        {true, false, {ok, Generation}, {ok, PlanBlob},
         {ok, [_ | _] = Reasons}} ->
            BeginRef = maps:get(ref, BeginEntry),
            Begin = quod_dtx:control_body(maps:get(control, BeginEntry)),
            Expected = prepare_record(Begin, BeginRef, Target),
            {ok, _Manifest, _PlanDigest, PlanBlob} =
                quod_dtx:prepare_payload(Expected),
            case quod_dtx:record_digest(Expected) of
                SemanticDigest -> {ok, {Target, Reasons}};
                _ -> error
            end;
        _ ->
            error
    end;
validate_refusal(_, _, _, _) ->
    error.

decode_refusal_reasons({Ns, Anchor}, ReasonsBlob) ->
    case quod_wire_term:decode_failure_reasons(ReasonsBlob) of
        {ok, [{prepare_refused, {ontology, Ns, Anchor}}, _Actual | _] = Reasons} ->
            {ok, Reasons};
        _ ->
            error
    end;
decode_refusal_reasons(_, _) ->
    error.

%% ===================================================================
%% Exact semantic phase-chain validation
%% ===================================================================

validate_chain(Begin, #{'begin' := none, prepares := Prepares,
                        decision := Decision, finalizes := Finalizes,
                        complete := Complete}, Generations, _Context) ->
    case {map_size(Prepares), Decision, map_size(Finalizes), Complete,
          map_size(Generations)} of
        {0, none, 0, none, 0} ->
            %% No durable group exists yet; the journaled Begin is enough to
            %% redrive its first submission.
            case quod_dtx:begin_recovery_rows(Begin) of
                {ok, _, _, _} -> ok;
                error -> {error, invalid_begin}
            end;
        _ -> {error, invalid_phase_chain}
    end;
validate_chain(Begin, Index, Generations, Context) ->
    #{'begin' := BeginEntry} = Index,
    BeginControl = maps:get(control, BeginEntry),
    BeginRef = maps:get(ref, BeginEntry),
    case quod_dtx:control_body(BeginControl) =:= Begin of
        false -> {error, invalid_phase_chain};
        true ->
            case validate_prepares(Begin, BeginRef, Index, Context) of
                ok ->
                    case validate_decision(BeginRef, Index, Context) of
                        ok ->
                            case validate_finalizes(
                                   Index, Generations, Context) of
                                ok -> validate_complete(Index, Context);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

validate_prepares(Begin, BeginRef, #{prepares := Prepares},
                  #{rows := Rows}) ->
    lists:foldl(
      fun(_Row, {error, _} = Error) -> Error;
         ({Target, _PlanBlob}, ok) ->
              case maps:get(Target, Prepares, none) of
                  none -> ok;
                  #{control := Control} ->
                      case quod_dtx:new_prepare(
                             Begin, BeginRef, Target) of
                          {ok, Expected} ->
                              case quod_dtx:control_body(Control) =:= Expected
                                   andalso quod_dtx:prepare_matches_begin(
                                             Control, Begin) of
                                  true -> ok;
                                  false -> {error, invalid_phase_chain}
                              end;
                          {error, _} -> {error, invalid_phase_chain}
                      end
              end
      end, ok, Rows).

validate_decision(_BeginRef, #{decision := none, finalizes := Finalizes,
                               complete := Complete}, _Context) ->
    case {map_size(Finalizes), Complete} of
        {0, none} -> ok;
        _ -> {error, invalid_phase_chain}
    end;
validate_decision(BeginRef, #{decision := Decision,
                              prepares := Prepares},
                  #{targets := Targets, group_id := GroupId}) ->
    Control = maps:get(control, Decision),
    Body = quod_dtx:control_body(Control),
    case quod_dtx:recovery_phase(Body) of
        {ok, #{kind := decision, group_id := GroupId,
               begin_ref := BeginRef, verdict := Verdict,
               prepare_rows := Rows, reasons := Reasons}} ->
            KnownRows = prepare_rows(Targets, Prepares),
            ValidRows =
                case Verdict of
                    commit -> Rows =:= KnownRows andalso
                                  length(KnownRows) =:= length(Targets);
                    abort -> ordered_subset(Rows, KnownRows)
                end,
            DecisionInput =
                case {Verdict, Reasons} of
                    {commit, none} -> commit;
                    {abort, [_ | _]} -> {abort, Reasons};
                    _ -> invalid
                end,
            case ValidRows andalso DecisionInput =/= invalid of
                true ->
                    case quod_dtx:new_decision(
                           GroupId, BeginRef, DecisionInput, Rows) of
                        {ok, Body} -> ok;
                        _ -> {error, invalid_phase_chain}
                    end;
                false -> {error, invalid_phase_chain}
            end;
        _ -> {error, invalid_phase_chain}
    end.

validate_finalizes(#{decision := none, finalizes := Finalizes},
                    _Generations, _Context) ->
    case map_size(Finalizes) of
        0 -> ok;
        _ -> {error, invalid_phase_chain}
    end;
validate_finalizes(#{decision := Decision, prepares := Prepares,
                     finalizes := Finalizes}, Generations,
                   #{targets := Targets, group_id := GroupId}) ->
    DecisionRef = maps:get(ref, Decision),
    {ok, #{verdict := DecisionVerdict}} =
        quod_dtx:recovery_phase(
          quod_dtx:control_body(maps:get(control, Decision))),
    lists:foldl(
      fun(_Target, {error, _} = Error) -> Error;
         (Target, ok) ->
              case maps:get(Target, Finalizes, none) of
                  none -> ok;
                  #{control := Control} ->
                      validate_finalize(
                        Target, quod_dtx:control_body(Control), DecisionRef,
                        DecisionVerdict, Prepares, Generations, GroupId)
              end
      end, ok, Targets).

validate_finalize(Target, Body, DecisionRef, DecisionVerdict,
                  Prepares, Generations, GroupId) ->
    case {quod_dtx:recovery_phase(Body), maps:find(Target, Generations)} of
        {{ok, #{kind := finalize, group_id := GroupId,
                decision_ref := DecisionRef, verdict := DecisionVerdict,
                prepare_ref := PrepareRef, generation := AppliedGeneration}},
         {ok, BaseGeneration}} ->
            case valid_finalize_prepare(
                   Target, DecisionVerdict, PrepareRef, Prepares) of
                true ->
                    case applied_generation(
                           DecisionVerdict, PrepareRef, BaseGeneration) of
                        {ok, AppliedGeneration} ->
                            case quod_dtx:new_finalize(
                                   GroupId, DecisionRef, DecisionVerdict,
                                   PrepareRef, AppliedGeneration) of
                                {ok, Body} -> ok;
                                _ -> {error, invalid_phase_chain}
                            end;
                        _ -> {error, invalid_generations}
                    end;
                false -> {error, invalid_phase_chain}
            end;
        {{ok, _}, error} -> {error, invalid_generations};
        _ -> {error, invalid_phase_chain}
    end.

valid_finalize_prepare(Target, commit, PrepareRef, Prepares) ->
    evidence_ref(Target, Prepares) =:= PrepareRef andalso PrepareRef =/= none;
valid_finalize_prepare(Target, abort, none, Prepares) ->
    not maps:is_key(Target, Prepares);
valid_finalize_prepare(Target, abort, PrepareRef, Prepares) ->
    evidence_ref(Target, Prepares) =:= PrepareRef andalso PrepareRef =/= none.

validate_complete(#{complete := none}, _Context) ->
    ok;
validate_complete(#{decision := Decision, finalizes := Finalizes,
                    complete := Complete},
                  #{targets := Targets, group_id := GroupId}) ->
    case {Decision, map_size(Finalizes) =:= length(Targets)} of
        {none, _} -> {error, invalid_phase_chain};
        {_, false} -> {error, invalid_phase_chain};
        {_, true} ->
            DecisionRef = maps:get(ref, Decision),
            case finalize_rows(Targets, Finalizes) of
                {ok, Rows} ->
                    case quod_dtx:new_complete(GroupId, DecisionRef, Rows) of
                        {ok, Expected} ->
                            case quod_dtx:control_body(
                                   maps:get(control, Complete)) =:= Expected of
                                true -> ok;
                                false -> {error, invalid_phase_chain}
                            end;
                        _ -> {error, invalid_phase_chain}
                    end;
                error -> {error, invalid_phase_chain}
            end
    end.

%% ===================================================================
%% Recovery command planning
%% ===================================================================

drive(_Begin, #{complete := #{ref := Ref}}, _Generations,
      _Applied, _Refusal, _Context) ->
    {done, Ref};
drive(Begin, #{'begin' := none}, _Generations, _Applied, none,
      #{origin := Origin}) ->
    {ok, [{submit, Origin, Begin}]};
drive(Begin, #{'begin' := BeginEntry, decision := none,
                prepares := Prepares} = _Index,
      _Generations, _Applied, Refusal,
      #{origin := Origin, group_id := GroupId, targets := Targets,
        rows := Rows}) ->
    BeginRef = maps:get(ref, BeginEntry),
    case Refusal of
        none ->
            Missing =
                [{submit, Target, prepare_record(Begin, BeginRef, Target)}
                 || {Target, _PlanBlob} <- Rows,
                    not maps:is_key(Target, Prepares)],
            case Missing of
                [_ | _] -> {ok, Missing};
                [] ->
                    PrepareRows = prepare_rows(Targets, Prepares),
                    decision_command(
                      Origin, GroupId, BeginRef, commit, PrepareRows)
            end;
        {_RefusedTarget, Reasons} ->
            decision_command(
              Origin, GroupId, BeginRef, {abort, Reasons},
              prepare_rows(Targets, Prepares))
    end;
drive(_Begin, #{decision := Decision, prepares := Prepares,
                finalizes := Finalizes} = Index,
      Generations, Applied, _Refusal,
      #{group_id := GroupId, origin := Origin, targets := Targets}) ->
    DecisionRef = maps:get(ref, Decision),
    {ok, #{verdict := Verdict}} =
        quod_dtx:recovery_phase(
          quod_dtx:control_body(maps:get(control, Decision))),
    FinalizeCommands =
        missing_finalize_commands(
          Targets, Finalizes, Prepares, Generations,
          GroupId, DecisionRef, Verdict),
    case FinalizeCommands of
        [_ | _] -> {ok, FinalizeCommands};
        [] ->
            AppliedCommands =
                missing_applied_commands(
                  Targets, Finalizes, Applied, GroupId),
            case AppliedCommands of
                [_ | _] -> {ok, AppliedCommands};
                [] -> complete_command(
                        Origin, GroupId, DecisionRef, Targets, Index)
            end
    end.

prepare_record(Begin, BeginRef, Target) ->
    {ok, Record} = quod_dtx:new_prepare(Begin, BeginRef, Target),
    Record.

decision_command(Origin, GroupId, BeginRef, Decision, PrepareRows) ->
    case quod_dtx:new_decision(GroupId, BeginRef, Decision, PrepareRows) of
        {ok, Record} -> {ok, [{submit, Origin, Record}]};
        {error, Reason} -> {error, {decision_construction, Reason}}
    end.

missing_finalize_commands(Targets, Finalizes, Prepares, Generations,
                          GroupId, DecisionRef, Verdict) ->
    lists:flatmap(
      fun(Target) ->
          case maps:is_key(Target, Finalizes) of
              true -> [];
              false ->
                  case maps:find(Target, Generations) of
                      error -> [{phase, Target, GroupId, prepare}];
                      {ok, BaseGeneration} ->
                          PrepareRef = finalize_prepare_ref(
                                         Target, Verdict, Prepares),
                          case applied_generation(
                                 Verdict, PrepareRef, BaseGeneration) of
                              {ok, AppliedGeneration} ->
                                  case quod_dtx:new_finalize(
                                         GroupId, DecisionRef, Verdict,
                                         PrepareRef, AppliedGeneration) of
                                      {ok, Record} ->
                                          [{submit, Target, Record}];
                                      {error, _} ->
                                          [{phase, Target, GroupId, prepare}]
                                  end;
                              error ->
                                  [{phase, Target, GroupId, prepare}]
                          end
                  end
          end
      end, Targets).

finalize_prepare_ref(Target, commit, Prepares) ->
    evidence_ref(Target, Prepares);
finalize_prepare_ref(Target, abort, Prepares) ->
    evidence_ref(Target, Prepares).

applied_generation(commit, PrepareRef, Generation)
  when PrepareRef =/= none, Generation < ?MAX_UINT64 ->
    {ok, Generation + 1};
applied_generation(abort, _PrepareRef, Generation)
  when Generation =< ?MAX_UINT64 ->
    {ok, Generation};
applied_generation(_, _, _) ->
    error.

missing_applied_commands(Targets, Finalizes, Applied, GroupId) ->
    lists:flatmap(
      fun(Target) ->
          #{control := Control, ref := FinalizeRef} =
              maps:get(Target, Finalizes),
          {ok, #{verdict := Verdict, prepare_ref := PrepareRef,
                 generation := Generation}} =
              quod_dtx:recovery_phase(quod_dtx:control_body(Control)),
          case {PrepareRef, maps:is_key(Target, Applied)} of
              {none, _} -> [];
              {_, true} -> [];
              {_, false} ->
                  [{applied, Target, GroupId, FinalizeRef,
                    Generation, Verdict}]
          end
      end, Targets).

complete_command(Origin, GroupId, DecisionRef, Targets,
                 #{finalizes := Finalizes}) ->
    case finalize_rows(Targets, Finalizes) of
        {ok, Rows} ->
            case quod_dtx:new_complete(GroupId, DecisionRef, Rows) of
                {ok, Record} -> {ok, [{submit, Origin, Record}]};
                {error, Reason} -> {error, {complete_construction, Reason}}
            end;
        error -> {error, invalid_phase_chain}
    end.

%% ===================================================================
%% Small canonical row helpers
%% ===================================================================

prepare_rows(Targets, Prepares) ->
    [{Target, maps:get(ref, maps:get(Target, Prepares))}
     || Target <- Targets, maps:is_key(Target, Prepares)].

finalize_rows(Targets, Finalizes) ->
    finalize_rows(Targets, Finalizes, []).

finalize_rows([], _Finalizes, Acc) ->
    {ok, lists:reverse(Acc)};
finalize_rows([Target | Rest], Finalizes, Acc) ->
    case maps:get(Target, Finalizes, none) of
        #{control := Control, ref := Ref} ->
            case quod_dtx:recovery_phase(quod_dtx:control_body(Control)) of
                {ok, #{kind := finalize, generation := Generation}} ->
                    finalize_rows(
                      Rest, Finalizes, [{Target, Ref, Generation} | Acc]);
                _ -> error
            end;
        none -> error
    end.

evidence_ref(Target, Rows) ->
    case maps:get(Target, Rows, none) of
        #{ref := Ref} -> Ref;
        none -> none
    end.

ordered_subset([], _All) -> true;
ordered_subset(_, []) -> false;
ordered_subset([Row = {Identity, _} | Rest],
               [Row = {Identity, _} | AllRest]) ->
    ordered_subset(Rest, AllRest);
ordered_subset([{Identity, _} | _] = Wanted,
               [{Candidate, _} | AllRest])
  when Candidate < Identity ->
    ordered_subset(Wanted, AllRest);
ordered_subset(_, _) -> false.
