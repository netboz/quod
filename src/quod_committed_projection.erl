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

-ifdef(TEST).
-export([test_publication_item/5]).
-endif.

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
        #{kind := dtx_batch, controls := [quod_dtx:control()],
          items := [map()],
          publications := [tuple()], applied_ops := [op()],
          changed_heads := [term()], deferred_acks := [tuple()],
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
        {controls, TaggedControls} ->
            apply_dtx_batch_entry(
              [Control || {_Kind, Control} <- TaggedControls],
              Entry, Floor, Projection0);
        noop ->
            publish(Index, Floor, Projection0, result(noop));
        invalid ->
            publish(Index, Floor, Projection0,
                    (result(unexpected))#{payload => Data})
    end;
apply_entry(_Entry, _Floor, _Projection) ->
    {error, bad_projection_entry}.

apply_content_entry(Transactions, Timestamp, Index, Floor, Projection0) ->
    case prepare_genesis_modules(Transactions, Index, Projection0) of
        {ok, ProjectionPrepared} ->
            apply_prepared_content_entry(
              Transactions, Timestamp, Index, Floor, ProjectionPrepared);
        {error, _} = Error -> Error
    end.

prepare_genesis_modules(
  [Genesis], 1,
  Projection = #projection{applied = 0, est = Est}) ->
    case quod_simplex:genesis_predicate_manifest(Genesis) of
        {ok, Manifest} ->
            case quod_predicates:load_manifest(Est, Manifest) of
                {ok, Est1} -> {ok, Projection#projection{est = Est1}};
                {error, Reason} ->
                    {error, {predicate_modules_unavailable, Reason}}
            end;
        %% Structural commit validation is the single authority that rejects a
        %% missing or malformed slot-1 manifest.  Defer here so projection and
        %% validation share that verdict instead of inventing a second one.
        error -> {ok, Projection}
    end;
prepare_genesis_modules(_Transactions, _Index, Projection) ->
    {ok, Projection}.

apply_prepared_content_entry(
  Transactions, Timestamp, Index, Floor, Projection0) ->
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
    case Change#transaction.role of
        {remote_application, _, _, _} ->
            apply_remote_application(Change, Index, Prior, Projection);
        {remote_claim, _, _, _} ->
            commit_transaction(Change, Index, Prior, [], [], Projection);
        {remote_complete, _, _, _} ->
            commit_transaction(Change, Index, Prior, [], [], Projection);
        application ->
            apply_application_transaction(
              Change, Diff, Index, Prior, Projection, Est)
    end.

apply_application_transaction(Change, Diff, Index, Prior, Projection, Est) ->
    case membership_change(Change) of
        true ->
            {ok, Est1, AppliedOps} = quod_diff:apply_ops_report(Est, Diff),
            commit_transaction(Change, Index, Prior, Diff, AppliedOps,
                               Projection#projection{est = Est1});
        false ->
            apply_ordinary_transaction(Change, Index, Prior, Projection)
    end.

apply_remote_application(Change, Index, Prior, Projection) ->
    case quod_commit_validation:remote_application(
           Change, validation_context(Projection)) of
        {apply, _EventContext, #{diff := Diff}} ->
            {ok, Est1, AppliedOps} = quod_diff:apply_ops_report(
                                       Projection#projection.est, Diff),
            commit_transaction(
              Change, Index, Prior, Diff, AppliedOps,
              Projection#projection{est = Est1});
        {reject, Reason} when is_atom(Reason) ->
            reject_transaction(Change, Index, Prior, Reason, Projection);
        {invalid, Reason} ->
            {error, {invalid_remote_application, Index, Reason}};
        abstain ->
            {error, {invalid_remote_application, Index, future_parent}}
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

apply_dtx_batch_entry(Controls,
                      #entry{index = Index, timestamp = Timestamp} = Entry,
                      Floor, Projection0) ->
    case validate_dtx_batch(
           Controls, Entry, Timestamp, Index, Projection0, [], #{}) of
        {ok, ControlRefs, Histories, Projection1} ->
            ProjectionState0 = maps:get(
                                 projection,
                                 quod_outcome:dtx_state(
                                   Projection1#projection.outcomes)),
            case quod_dtx:reduce_batch(
                   ControlRefs, Histories, ProjectionState0) of
                {ok, _Histories1, _ProjectionState1, Items} ->
                    apply_reduced_dtx_batch(
                      Items, Index, Floor, Projection1,
                      [], [], [], [], [], stats());
                Other ->
                    {error, {invalid_dtx_transition, Other}}
            end;
        {wait, Reason, Projection1} ->
            {wait, network_identity, Reason, Projection1};
        {error, Reason} ->
            {error, {invalid_committed_dtx, Index, Reason}}
    end.

validate_dtx_batch([], _Entry, _Timestamp, _Index, Projection,
                   ControlRefs, Histories) ->
    {ok, lists:reverse(ControlRefs), Histories, Projection};
validate_dtx_batch([Control | Rest], Entry, Timestamp, Index,
                   Projection0 = #projection{target = Binding},
                   ControlRefs, Histories0) ->
    case quod_dtx:verify_control(Binding, Control) of
        false -> {error, bad_control_signature};
        true ->
            case quod_dtx:certified_entry_ref(Binding, Entry, Control) of
                {ok, Ref} ->
                    case quod_commit_validation:dtx(
                           Control, Timestamp, {claim, Index},
                           validation_context(Projection0)) of
                        {ok, {valid, History}, Context} ->
                            GroupId = quod_dtx:group_id(Control),
                            validate_dtx_batch(
                              Rest, Entry, Timestamp, Index,
                              set_validation_context(Context, Projection0),
                              [{Control, Ref} | ControlRefs],
                              Histories0#{GroupId => History});
                        {ok, {unavailable, network_identity, Reason}, Context} ->
                            {wait, Reason,
                             set_validation_context(Context, Projection0)};
                        {ok, Invalid, _Context} -> {error, Invalid};
                        {outcome_error, Reason} -> {error, {outcome_index, Reason}}
                    end;
                {error, Reason} -> {error, Reason}
            end
    end.

apply_reduced_dtx_batch([], Index, Floor, Projection,
                        Controls, ResultItems, Publications, AppliedOpChunks,
                        DeferredAcks, Stats) ->
    AppliedOps = lists:append(lists:reverse(AppliedOpChunks)),
    publish(
      Index, Floor, Projection,
      #{kind => dtx_batch, controls => lists:reverse(Controls),
        items => lists:reverse(ResultItems),
        publications => lists:reverse(Publications),
        applied_ops => AppliedOps, changed_heads => changed_heads(AppliedOps),
        deferred_acks => lists:reverse(DeferredAcks), stats => Stats});
apply_reduced_dtx_batch(
  [#{control := Control, history := History,
     projection := ProjectionState, effects := Effects} | Rest],
  Index, Floor, Projection0 = #projection{outcomes = Outcomes0},
  Controls0, ResultItems0, Publications0, AppliedOps0,
  DeferredAcks0, Stats0) ->
    case apply_dtx_effects(Effects, Index, Projection0) of
        {ok, Projection1, Publication, AppliedOps, Delta} ->
            case quod_outcome:apply_dtx(
                   Outcomes0, Index, Control, History, ProjectionState, Effects) of
                {ok, Outcomes1, DeferredAck} ->
                    Publications1 = case Publication of
                                        none -> Publications0;
                                        _ -> [Publication | Publications0]
                                    end,
                    DeferredAcks1 = case DeferredAck of
                                        none -> DeferredAcks0;
                                        _ -> [DeferredAck | DeferredAcks0]
                                    end,
                    ResultItem = publication_item(
                                   Control, Publication, AppliedOps,
                                   DeferredAck, Delta),
                    apply_reduced_dtx_batch(
                      Rest, Index, Floor,
                      Projection1#projection{outcomes = Outcomes1},
                      [Control | Controls0], [ResultItem | ResultItems0],
                      Publications1,
                      [AppliedOps | AppliedOps0],
                      DeferredAcks1, add_stats(Stats0, Delta));
                {error, Reason} -> {error, {outcome_index, Reason}}
            end;
        {error, _} = Error -> Error
    end.

publication_item(Control, Publication, AppliedOps, DeferredAck, Delta) ->
    #{control => Control, group_id => quod_dtx:group_id(Control),
      publication => Publication, applied_ops => AppliedOps,
      changed_heads => changed_heads(AppliedOps),
      deferred_ack => DeferredAck, stats => Delta}.

-ifdef(TEST).
test_publication_item(Control, Publication, AppliedOps, DeferredAck, Delta) ->
    publication_item(Control, Publication, AppliedOps, DeferredAck, Delta).
-endif.

apply_dtx_effects(Effects, Index, Projection) when is_list(Effects) ->
    apply_dtx_effects(Effects, Index, Projection, none, [], stats()).

apply_dtx_effects([], _Index, Projection, Publication, AppliedOps, Stats) ->
    {ok, Projection, Publication, AppliedOps, Stats};
apply_dtx_effects([Effect | Rest], Index, Projection0,
                  Publication0, AppliedOps0, Stats0) ->
    case apply_dtx_effect(Effect, Index, Projection0) of
        {ok, Projection1, Publication1, AppliedOps1, Delta} ->
            case merge_publication(Publication0, Publication1) of
                {ok, Publication} ->
                    apply_dtx_effects(
                      Rest, Index, Projection1, Publication,
                      AppliedOps0 ++ AppliedOps1,
                      add_stats(Stats0, Delta));
                error ->
                    {error,
                     {invalid_committed_dtx_effects, Index,
                      [Effect | Rest]}}
            end;
        {error, _} = Error -> Error
    end.

merge_publication(none, Publication) -> {ok, Publication};
merge_publication(Publication, none) -> {ok, Publication};
merge_publication(_, _) -> error.

apply_dtx_effect(
  {prepared, _GroupId, _Ref, _Manifest, _PlanDigest, _PlanBlob,
   _Generation}, _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effect(
  {apply_prepared, GroupId, Manifest, PlanDigest, PlanBlob,
   _Ref, _Generation}, Index,
  Projection = #projection{est = Est}) ->
    case quod_commit_validation:prepared_material(
           Manifest, PlanDigest, PlanBlob, validation_context(Projection)) of
        {ok, EventContext, #{diff := Diff, effects := DirectEffects}} ->
            {ok, Est1, AppliedOps} = quod_diff:apply_ops_report(Est, Diff),
            {ok, Projection#projection{est = Est1},
             {group_applied, GroupId, EventContext, Diff, DirectEffects},
             AppliedOps,
             #{applies => 1, rejects => 0, conflicts => 0}};
        {error, Reason} ->
            {error, {invalid_committed_dtx_finalize, Index, Reason}}
    end;
apply_dtx_effect(
  {discard_prepared, _GroupId, _Manifest, _PlanDigest, _PlanBlob,
   _Ref, _Generation}, _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effect({origin_started, _GroupId, _Ref}, _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effect({decided, _GroupId, _Verdict, _Ref}, _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effect(
  {direct_applied_abort, _GroupId, _Ref, _Generation}, _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effect(
  {completed, _GroupId, commit, _Ref}, _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effect(
  {completed, _GroupId, abort, _Ref, _Reasons}, _Index, Projection) ->
    {ok, Projection, none, [], stats()};
apply_dtx_effect(Effect, Index, _Projection) ->
    {error, {invalid_committed_dtx_effects, Index, Effect}}.

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
      [Head || {Kind, {Head, _Body}} <- AppliedOps,
               Kind =:= assert orelse Kind =:= retract], #{}, []).

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
