-module(quod_committed_projection).
-moduledoc """
Canonical process-free materializer for one ontology's certified ledger.

The projection owns only rebuildable committed state: the MVCC knowledge base,
the outcome projection, and the ordered applied height.  `apply_entry/3` is the
one state-transition path used by the live Prolog owner and by foreign
subscription followers.  It performs no messaging, client completion,
runtime publication, effect-journal mutation, or consensus acknowledgement;
those owner-local consequences are returned as bounded result descriptors.

The caller has already verified the ledger certificate.  This module still
validates every semantic record exactly as committed apply does: request
evidence, operation claims, OCC, policy preservation, DTX history, and hidden
prepared material all pass through the existing canonical validators.
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([new_est/0, read_terms/1, new/5, apply_entry/3,
         target/1, applied/1, est/1, outcomes/1]).
-export_type([projection/0, result/0]).

-record(projection, {
          target :: {binary(), <<_:256>>},
          applied = 0 :: non_neg_integer(),
          est :: tuple(),
          outcomes :: quod_outcome:index(),
          signer :: quod_identity:signer() | none
         }).

-opaque projection() :: #projection{}.
-type stats() :: #{applies := non_neg_integer(),
                   rejects := non_neg_integer(),
                   conflicts := non_neg_integer()}.
-type result() ::
        #{kind := content, transactions := [map()], stats := stats()} |
        #{kind := dtx, control := quod_dtx:control(),
          group_id := <<_:256>>, publication := none | tuple(),
          applied_ops := [op()], changed_heads := [term()],
          deferred_ack := none | tuple(),
          stats := stats()} |
        #{kind := noop, stats := stats()} |
        #{kind := unexpected, payload := term(), stats := stats()} |
        #{kind := already_applied, stats := stats()}.

-doc "Build the shared height-zero Erlog/MVCC base for any committed projection owner.".
-spec new_est() -> tuple().
new_est() ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    Est0 = element(3, Erl),
    EstReasonBounded = erlog_int:set_failure_reason_policy(
                         {quod_wire_term, valid_failure_reason_stack}, Est0),
    {succeed, Est1} = erlog_int:prove_goal(
                        {set_prolog_flag, unknown, fail}, EstReasonBounded),
    Est2 = quod_predicates:load(Est1),
    Est3 = quod_ask:load(Est2),
    Est4 = quod_transaction_predicates:load(Est3),
    Est5 = quod_action_predicates:load(Est4),
    #est{db = #db{ref = Ref0} = Db} = Est6 = load_common_predicates(Est5),
    Est6#est{db = Db#db{
                       ref = quod_erlog_db_mvcc:publish_base(Ref0)}}.

-doc "Parse one Prolog source file with the canonical genesis error contract.".
-spec read_terms(file:filename()) -> [term()].
read_terms(File) ->
    Result = try erlog_io:read_file(File)
             catch Class0:Reason0 -> {caught, Class0, Reason0}
             end,
    case Result of
        {ok, Terms} -> Terms;
        {error, Reason} ->
            throw({genesis_failed, {read_file, File, Reason}});
        {caught, Class, Reason} ->
            throw({genesis_failed, {parse, File, {Class, Reason}}})
    end.

-spec new({binary(), <<_:256>>}, non_neg_integer(), tuple(),
          quod_outcome:index(), quod_identity:signer() | none) -> projection().
new({Ns, <<_:256>>} = Target, Applied, Est, Outcomes, Signer)
  when is_binary(Ns), is_integer(Applied), Applied >= 0, is_tuple(Est) ->
    #projection{target = Target, applied = Applied, est = Est,
                outcomes = Outcomes, signer = Signer}.

-spec target(projection()) -> {binary(), <<_:256>>}.
target(#projection{target = Target}) -> Target.

-spec applied(projection()) -> non_neg_integer().
applied(#projection{applied = Applied}) -> Applied.

-spec est(projection()) -> tuple().
est(#projection{est = Est}) -> Est.

-spec outcomes(projection()) -> quod_outcome:index().
outcomes(#projection{outcomes = Outcomes}) -> Outcomes.

-spec apply_entry(#entry{}, non_neg_integer(), projection()) ->
          {ok, projection(), result()} |
          {wait, network_identity, term(), projection()} |
          {error, term()}.
apply_entry(#entry{index = Index}, _Floor,
            Projection = #projection{applied = Applied})
  when Index =< Applied ->
    {ok, Projection, result(already_applied)};
apply_entry(#entry{index = Index}, _Floor,
            #projection{applied = Applied})
  when Index =/= Applied + 1 ->
    {error, {projection_gap, Applied, Index}};
apply_entry(#entry{index = Index, data = Data,
                   timestamp = Timestamp} = Entry,
            Floor, Projection0) when Floor >= 0, Floor =< Index ->
    case quod_ledger:classify(Data) of
        {content, Transactions} ->
            apply_content_entry(Transactions, Timestamp, Index,
                                Floor, Projection0);
        {'begin', Control} ->
            apply_dtx_entry(Control, Entry, Floor, Projection0);
        {prepare, Control} ->
            apply_dtx_entry(Control, Entry, Floor, Projection0);
        {decision, Control} ->
            apply_dtx_entry(Control, Entry, Floor, Projection0);
        {finalize, Control} ->
            apply_dtx_entry(Control, Entry, Floor, Projection0);
        {complete, Control} ->
            apply_dtx_entry(Control, Entry, Floor, Projection0);
        noop ->
            publish(Index, Floor, Projection0, result(noop));
        invalid ->
            publish(Index, Floor, Projection0,
                    (result(unexpected))#{payload => Data})
    end;
apply_entry(_Entry, _Floor, _Projection) ->
    {error, bad_projection_entry}.

apply_content_entry(Transactions, Timestamp, Index, Floor, Projection0) ->
    case quod_commit_validation:content(
           Transactions, Timestamp, {claim, Index},
           validation_context(Projection0)) of
        {ok, valid, Context} ->
            Projection1 = set_validation_context(Context, Projection0),
            case apply_transactions(Transactions, Index, Projection1) of
                {ok, Projection2, Results, Stats} ->
                    publish(Index, Floor, Projection2,
                            #{kind => content, transactions => Results,
                              stats => Stats});
                {error, _} = Error ->
                    Error
            end;
        {ok, {unavailable, network_identity, Reason}, Context} ->
            {wait, network_identity, Reason,
             set_validation_context(Context, Projection0)};
        {ok, Invalid, _Context} ->
            {error, {invalid_committed_content, Index, Invalid}};
        {outcome_error, Reason} ->
            {error, {outcome_index, Reason}}
    end.

apply_transactions(Transactions, Index, Projection0) ->
    Folded = lists:foldl(
               fun(_Change, {error, _} = Error) ->
                       Error;
                  (Change, {ok, Projection, Results, Stats}) ->
                       case apply_transaction(Change, Index, Projection) of
                           {ok, Projection1, TxResult, Delta} ->
                               {ok, Projection1, [TxResult | Results],
                                add_stats(Stats, Delta)};
                           {error, _} = Error ->
                               Error
                       end
               end, {ok, Projection0, [], stats()}, Transactions),
    reverse_transaction_results(Folded).

reverse_transaction_results({ok, Projection, Results, Stats}) ->
    {ok, Projection, lists:reverse(Results), Stats};
reverse_transaction_results({error, _} = Error) ->
    Error.

apply_transaction(#transaction{plan_digest = none} = Change,
                  Index, Projection) ->
    apply_new_transaction(Change, Index, new, Projection);
apply_transaction(#transaction{} = Change, Index,
                  Projection0 = #projection{outcomes = Outcomes0}) ->
    case quod_outcome:classify(Outcomes0, Change) of
        {new, Candidate, Outcomes1} ->
            apply_new_transaction(
              Change, Index, {new, Candidate},
              Projection0#projection{outcomes = Outcomes1});
        {pending, Candidate, Outcomes1} ->
            apply_new_transaction(
              Change, Index, {pending, Candidate},
              Projection0#projection{outcomes = Outcomes1});
        {terminal, Stored, Outcomes1} ->
            apply_known_transaction(
              Change, Index, Stored,
              Projection0#projection{outcomes = Outcomes1});
        {error, Reason} ->
            {error, {outcome_index, Reason}}
    end.

apply_known_transaction(Change, Index, #{status := Status} = Stored,
                        Projection) ->
    case terminal_slot(Status) of
        Index ->
            apply_new_transaction(
              Change, Index, {terminal, Stored}, Projection);
        Slot when Slot < Index ->
            duplicate_transaction(Change, Stored, Projection);
        _ ->
            {error, {outcome_index, terminal_slot_order}}
    end.

terminal_slot({committed, Slot}) -> Slot;
terminal_slot({rejected, _Reason, Slot}) -> Slot;
terminal_slot(_) -> error({outcome_index_conflict, bad_status}).

apply_new_transaction(#transaction{diff = Diff} = Change, Index, Prior,
                      Projection = #projection{est = Est}) ->
    case membership_change(Change) of
        true ->
            {ok, Est1, AppliedOps} = quod_diff:apply_ops_report(Est, Diff),
            commit_transaction(Change, Index, Prior, Diff, AppliedOps,
                               Projection#projection{est = Est1});
        false ->
            apply_ordinary_transaction(Change, Index, Prior, Projection)
    end.

apply_ordinary_transaction(
  #transaction{diff = Diff, read_check = ReadCheck} = Change,
  Index, Prior,
  Projection = #projection{
                  est = #est{db = #db{mod = quod_erlog_db_mvcc,
                                      ref = Ref}} = Est}) ->
    case quod_diff:validate(ReadCheck, Ref) of
        ok ->
            case quod_diff:apply_ops_preserving_policy_report(Est, Diff) of
                {ok, Est1, AppliedOps} ->
                    commit_transaction(Change, Index, Prior, Diff, AppliedOps,
                                       Projection#projection{est = Est1});
                {error, policy_self_seal_forbidden} ->
                    reject_transaction(Change, Index, Prior,
                                       policy_self_seal_forbidden, Projection)
            end;
        {conflict, _Functor} ->
            reject_transaction(Change, Index, Prior, conflict_retry, Projection)
    end.

commit_transaction(Change, Index, Prior, Diff, AppliedOps, Projection0) ->
    case record_terminal(Change, Index, committed, Prior, Projection0) of
        {ok, Projection1} ->
            {ok, Projection1,
             #{status => applied, change => Change, height => Index,
               diff => Diff, applied_ops => AppliedOps,
               changed_heads => changed_heads(AppliedOps)},
             #{applies => 1, rejects => 0, conflicts => 0}};
        {error, _} = Error -> Error
    end.

reject_transaction(Change, Index, Prior, Reason, Projection0) ->
    case record_terminal(Change, Index, {rejected, Reason}, Prior,
                         Projection0) of
        {ok, Projection1} ->
            {ok, Projection1,
             #{status => rejected, change => Change, height => Index,
               reason => Reason, applied_ops => [], changed_heads => []},
             #{applies => 0, rejects => 1,
               conflicts => case Reason of conflict_retry -> 1; _ -> 0 end}};
        {error, _} = Error -> Error
    end.

duplicate_transaction(#transaction{tx_id = TxId} = Change,
                      Stored, Projection) ->
    case terminal_result(Stored) of
        {committed, Slot, TxId} ->
            {ok, Projection,
             #{status => duplicate_committed, change => Change,
               height => Slot, applied_ops => [], changed_heads => []}, stats()};
        {rejected, Reason} ->
            {ok, Projection,
             #{status => duplicate_rejected, change => Change,
               reason => Reason, applied_ops => [], changed_heads => []}, stats()};
        _ ->
            {error, outcome_index_corrupt}
    end.

terminal_result(#{tx_id := TxId, status := {committed, Slot}}) ->
    {committed, Slot, TxId};
terminal_result(#{status := {rejected, Reason, _Slot}}) ->
    {rejected, Reason};
terminal_result(_) ->
    error.

record_terminal(#transaction{plan_digest = none}, _Index, _Verdict, _Prior,
                Projection) ->
    {ok, Projection};
record_terminal(_Change, Index, Verdict, Prior,
                Projection = #projection{outcomes = Outcomes0}) ->
    case quod_outcome:terminal(Outcomes0, Index, Verdict, Prior) of
        {_NewOrDuplicate, _Stored, Outcomes1} ->
            {ok, Projection#projection{outcomes = Outcomes1}};
        {error, Reason} ->
            {error, {outcome_index, Reason}}
    end.

apply_dtx_entry(Control,
                #entry{index = Index, timestamp = Timestamp} = Entry,
                Floor, Projection0 = #projection{target = Binding}) ->
    case quod_dtx:verify_control(Binding, Control) of
        false ->
            {error, {invalid_committed_dtx, Index, bad_control_signature}};
        true ->
            case quod_dtx:certified_entry_ref(Binding, Entry, Control) of
                {ok, CertifiedRef} ->
                    apply_verified_dtx(Control, CertifiedRef, Timestamp,
                                       Index, Floor, Projection0);
                {error, Reason} ->
                    {error, {invalid_committed_dtx, Index, Reason}}
            end
    end.

apply_verified_dtx(Control, CertifiedRef, Timestamp, Index, Floor,
                   Projection0) ->
    case quod_commit_validation:dtx(
           Control, Timestamp, {claim, Index},
           validation_context(Projection0)) of
        {ok, {valid, History0}, Context} ->
            Projection1 = set_validation_context(Context, Projection0),
            reduce_dtx(Control, CertifiedRef, History0, Index, Floor,
                       Projection1);
        {ok, {unavailable, network_identity, Reason}, Context} ->
            {wait, network_identity, Reason,
             set_validation_context(Context, Projection0)};
        {ok, Invalid, _Context} ->
            {error, {invalid_committed_dtx, Index, Invalid}};
        {outcome_error, Reason} ->
            {error, {outcome_index, Reason}}
    end.

reduce_dtx(Control, CertifiedRef, History0, Index, Floor,
           Projection0 = #projection{outcomes = Outcomes0}) ->
    ProjectionState0 = maps:get(projection, quod_outcome:dtx_state(Outcomes0)),
    case quod_dtx:reduce(Control, CertifiedRef, History0, ProjectionState0) of
        {ok, History1, ProjectionState1, Effects} ->
            case apply_dtx_effects(Effects, Index, Projection0) of
                {ok, Projection1, Publication, AppliedOps, Delta} ->
                    case quod_outcome:apply_dtx(
                           Projection1#projection.outcomes, Index, Control,
                           History1, ProjectionState1, Effects) of
                        {ok, Outcomes1, DeferredAck} ->
                            GroupId = quod_dtx:group_id(Control),
                            publish(
                              Index, Floor,
                              Projection1#projection{outcomes = Outcomes1},
                              #{kind => dtx, control => Control,
                                group_id => GroupId,
                                publication => Publication,
                                applied_ops => AppliedOps,
                                changed_heads => changed_heads(AppliedOps),
                                deferred_ack => DeferredAck,
                                stats => Delta});
                        {error, Reason} ->
                            {error, {outcome_index, Reason}}
                    end;
                {error, _} = Error ->
                    Error
            end;
        Other ->
            {error, {invalid_dtx_transition, Other}}
    end.

apply_dtx_effects([], _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effects(
  [{prepared, _GroupId, _Ref, _Manifest, _PlanDigest, _PlanBlob,
    _Generation}], _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effects(
  [{apply_prepared, GroupId, Manifest, PlanDigest, PlanBlob,
    _Ref, _Generation}], Index,
  Projection = #projection{est = Est}) ->
    case quod_commit_validation:prepared_material(
           Manifest, PlanDigest, PlanBlob, validation_context(Projection)) of
        {ok, EventContext, #{diff := Diff}} ->
            {ok, Est1, AppliedOps} = quod_diff:apply_ops_report(Est, Diff),
            {ok, Projection#projection{est = Est1},
             {group_applied, GroupId, EventContext, Diff}, AppliedOps,
             #{applies => 1, rejects => 0, conflicts => 0}};
        {error, Reason} ->
            {error, {invalid_committed_dtx_finalize, Index, Reason}}
    end;
apply_dtx_effects(
  [{discard_prepared, _GroupId, _Manifest, _PlanDigest, _PlanBlob,
    _Ref, _Generation}], _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effects([{origin_started, _GroupId, _Ref}], _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effects([{decided, _GroupId, _Verdict, _Ref}], _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effects(
  [{direct_applied_abort, _GroupId, _Ref, _Generation}], _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effects(
  [{completed, _GroupId, commit, _Ref}], _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effects(
  [{completed, _GroupId, abort, _Ref, _Reasons}], _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effects(Effects, Index, _Projection) ->
    {error, {invalid_committed_dtx_effects, Index, Effects}}.

publish(Index, Floor,
        Projection0 = #projection{
                        est = #est{db = #db{mod = quod_erlog_db_mvcc,
                                            ref = Ref0} = Db} = Est,
                        outcomes = Outcomes0}, Result) ->
    case quod_outcome:advance_applied(Outcomes0, Index) of
        {ok, OutcomesStaged} ->
            case quod_outcome:flush(OutcomesStaged) of
                {ok, Outcomes1} ->
                    Ref1 = quod_erlog_db_mvcc:commit(Ref0, Index, Floor),
                    Projection1 = Projection0#projection{
                                    est = Est#est{db = Db#db{ref = Ref1}},
                                    outcomes = Outcomes1, applied = Index},
                    {ok, Projection1, Result};
                {error, Reason} ->
                    {error, {outcome_index, Reason}}
            end;
        {error, Reason} ->
            {error, {outcome_index, Reason}}
    end.

validation_context(
  #projection{target = Target, applied = Applied, est = Est,
              outcomes = Outcomes, signer = Signer}) ->
    quod_commit_validation:new(Target, Applied, Est, Outcomes, Signer).

set_validation_context(Context, Projection) ->
    Projection#projection{outcomes = quod_commit_validation:outcomes(Context)}.

membership_change(Change) ->
    quod_simplex:committee_delta(Change) =/= {[], []}.

stats() -> #{applies => 0, rejects => 0, conflicts => 0}.

result(Kind) -> (stats_result())#{kind => Kind}.

stats_result() -> #{stats => stats()}.

add_stats(A, B) ->
    maps:map(fun(Key, Value) -> Value + maps:get(Key, B) end, A).

changed_heads(AppliedOps) ->
    stable_unique(
      [Head || {_Kind, {Head, _Body}} <- AppliedOps], #{}, []).

stable_unique([], _Seen, Rev) ->
    lists:reverse(Rev);
stable_unique([Value | Rest], Seen, Rev) ->
    case maps:is_key(Value, Seen) of
        true -> stable_unique(Rest, Seen, Rev);
        false -> stable_unique(Rest, Seen#{Value => true}, [Value | Rev])
    end.

load_common_predicates(#est{db = Db0} = Est) ->
    File = filename:join(code:priv_dir(quod),
                         "ontologies/common_predicates.pl"),
    Terms =
        try read_terms(File)
        catch
            throw:{genesis_failed, ReadReason} ->
                throw({common_predicates_failed, ReadReason})
        end,
    try
        Db1 = lists:foldl(fun erlog_int:assertz_clause/2, Db0, Terms),
        Est#est{db = Db1}
    catch
        Class:LoadReason ->
            throw({common_predicates_failed, {Class, LoadReason}})
    end.
