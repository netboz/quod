-module(quod_operation).
-moduledoc """
Pure transitions for a durable operation and its exact target outcomes.

The existing Simplex, Prolog and coordinator processes supply installed state
and execute the resulting work. This library has no process, store, signing
key, clock, transport, scheduler or alternative application implementation.
""".

-include("quod_ledger.hrl").
-export([new/4, work/1, accept/5, restore_receipt/2, results/1, completion/1,
         references/1, request_digest/1, claim_bytes/1, claim/1, applied_result/3]).

%% This is the coordinator's disposable, bounded observation state. The claim
%% and the installed receipt remain the only durable authorities. A missing
%% certificate is not a rejection, and an included application is not work to
%% submit again. N=1 uses this same map and command selection.
-opaque operation() :: map().
-export_type([operation/0]).

-spec new(binary(), term(), quod_dtx:certified_ref(), #transaction{}) ->
          {ok, operation()} | {error, invalid_operation_claim}.
new(OwnerNs, OperationRef, ClaimRef,
    #transaction{origin = {OwnerNs, <<_:256>>} = Origin, tx_id = ClaimId,
                 role = {remote_claim, _, _, Refs}} = Claim) ->
    case {quod_dtx:certified_ref_binding(ClaimRef),
          quod_transaction:request_claim(Claim),
          quod_operation_vector:references(Refs)} of
        {{ok, Origin, _, ClaimId},
         {ok, #{operation_ref := OperationRef, digest := Digest}}, {ok, Refs}} ->
            StableClaim = quod_transaction:stable_ref(ClaimRef),
            try
                true = quod_transaction:valid_id(Origin, Claim),
                true = lists:all(fun(Ref) ->
                    Target = quod_operation_vector:target(Ref),
                    Route = quod_transaction:remote_claim_route(Claim, Target),
                    Route =:= shared orelse element(1, Route) =:= private
                end, Refs),
                %% The shared envelope validator already recomputes every
                %% predicted application ID from the authenticated opaque
                %% plans. Never construct target applications here: that is
                %% the target's materialization boundary, not observation.
                {ok, Bytes} = quod_transaction:encode_evidence(ClaimRef, Claim),
                {ok, #{origin => Origin, operation_ref => OperationRef,
                       request_digest => Digest, claim_ref => StableClaim,
                       claim => Claim, claim_bytes => Bytes, refs => Refs,
                       observations => #{}}}
            catch _:_ -> {error, invalid_operation_claim}
            end;
        _ -> {error, invalid_operation_claim}
    end;
new(_, _, _, _) -> {error, invalid_operation_claim}.

-spec references(operation()) -> [quod_operation_vector:application_ref()].
references(#{refs := Refs}) -> Refs.
-spec request_digest(operation()) -> <<_:256>>.
request_digest(#{request_digest := Digest}) -> Digest.
-spec claim_bytes(operation()) -> binary().
claim_bytes(#{claim_bytes := Bytes}) -> Bytes.
-spec claim(operation()) -> #transaction{}.
claim(#{claim := Claim}) -> Claim.

%% Target workers execute each command through apply -> verify -> certify,
%% independently of every other target's stage. Only the final vector joins.
-spec work(operation()) -> [{application, quod_operation_vector:target()} |
          {certify, quod_operation_vector:target(), quod_dtx:certified_ref(), map()}].
work(#{refs := Refs, observations := Observations}) ->
    lists:filtermap(fun(Ref) ->
        Target = quod_operation_vector:target(Ref),
        case maps:get(Target, Observations, none) of
            none -> {true, {application, Target}};
            #{certificate := _} -> false;
            #{reference := CertifiedRef, evidence := Evidence} ->
                {true, {certify, Target, CertifiedRef, Evidence}}
        end
    end, Refs).

%% The existing exact-history verifier and certificate collector are the
%% authority boundary; this transition pins their output to THIS claim. No
%% transport result label enters this function. Certificates are immutable
%% semantic statements: another valid signature subset cannot replace a row.
-spec accept(quod_operation_vector:target(), quod_dtx:certified_ref(), map(),
             none | quod_applied_certificate:operation_certificate(), operation()) ->
          {ok, operation()} | {error, atom()}.
accept(Target, Ref, #{transaction := Transaction} = Evidence, Certificate,
       #{refs := Refs, operation_ref := OperationRef, claim_ref := ClaimRef,
         request_digest := Digest, observations := Observations} = Operation) ->
    case {quod_operation_vector:lookup(Target, Refs),
          quod_dtx:certified_ref_claim(Ref), Transaction} of
        {{ok, {transaction, _, _, TxId} = StableRef},
         {ok, {Target, Slot, Hash, TxId}},
         #transaction{tx_id = TxId,
           role = {remote_application, ClaimRef, OperationRef, Digest}}} ->
            Row = #{reference => Ref, evidence => Evidence},
            case certificate_row(Certificate, Target, StableRef, Slot, Hash,
                                 OperationRef, ClaimRef, Row) of
                error -> {error, invalid_target_evidence};
                {ok, New} ->
                    case merge_observation(maps:get(Target, Observations, none), New) of
                        error -> {error, conflicting_target_evidence};
                        {ok, Kept} ->
                            {ok, Operation#{observations => Observations#{Target => Kept}}}
                    end
            end;
        _ -> {error, invalid_target_evidence}
    end;
accept(_, _, _, _, _) -> {error, invalid_target_evidence}.

certificate_row(none, _, _, _, _, _, _, Row) -> {ok, Row};
certificate_row(Cert, Target, StableRef, Slot, Hash, OperationRef, ClaimRef, Row) ->
    case quod_applied_certificate:operation_certificate_binding(Cert) of
        {ok, #{target := Target, application_ref := StableRef,
               operation_ref := OperationRef, claim_ref := ClaimRef,
               slot := Slot, entry_digest := Hash, result := _}} ->
            {ok, Row#{certificate => Cert}};
        _ -> error
    end.

merge_observation(none, New) -> {ok, New};
merge_observation(#{reference := OldRef} = Old, #{reference := NewRef} = New) ->
    case quod_dtx:same_certified_ref(OldRef, NewRef) of
        false -> error;
        true ->
            case {maps:find(certificate, Old), maps:find(certificate, New)} of
                {error, _} -> {ok, New};
                {{ok, _}, error} -> {ok, Old};
                {{ok, A}, {ok, B}} ->
                    {ok, #{statement := SA}} =
                        quod_applied_certificate:operation_certificate_binding(A),
                    {ok, #{statement := SB}} =
                        quod_applied_certificate:operation_certificate_binding(B),
                    case SA =:= SB of true -> {ok, Old}; false -> error end
            end
    end.

%% Input is an exact receipt from the source owner's already-verified ledger,
%% not an endpoint projection. Its application pairs are certified history.
%% Old included rows provide discovery only; work/1 still requires an AM3
%% certificate. No legacy decoder, receipt rewriting, or completed redelivery.
-spec restore_receipt(#transaction{}, operation()) -> {ok, operation()} | {error, atom()}.
restore_receipt(
  #transaction{role = {remote_complete, OperationRef, Digest, Rows},
               evidence = {applications, Pairs}},
  #{operation_ref := OperationRef, request_digest := Digest, refs := Refs} = Operation) ->
    case quod_operation_vector:receipt_references(Rows) of
        {ok, Refs} when length(Pairs) =:= length(Refs) ->
            lists:foldl(fun
                (_, {error, _} = Error) -> Error;
                ({Target, Arm}, {ok, Acc}) ->
                    StableRef = element(2, Arm),
                    case [{Ref, Tx} || {Ref, #transaction{} = Tx} <- Pairs,
                                      quod_transaction:stable_ref(Ref) =:= StableRef] of
                        [{Ref, Tx}] ->
                            Certificate = case Arm of
                                {included, _} -> none;
                                {certified, _, Cert} -> Cert
                            end,
                            accept(Target, Ref, #{transaction => Tx}, Certificate, Acc);
                        _ -> {error, invalid_completion}
                    end
            end, {ok, Operation}, Rows);
        _ -> {error, invalid_completion}
    end;
restore_receipt(_, _) -> {error, invalid_completion}.

-spec results(operation()) -> pending | {ok, list()}.
results(#{refs := Refs, observations := Observations}) ->
    case lists:all(fun(Ref) ->
        case maps:get(quod_operation_vector:target(Ref), Observations, none) of
            #{certificate := _} -> true;
            _ -> false
        end
    end, Refs) of
        false -> pending;
        true -> {ok, [result_row(Ref, Observations) || Ref <- Refs]}
    end.

result_row(Ref, Observations) ->
    Target = quod_operation_vector:target(Ref),
    #{certificate := Certificate} = maps:get(Target, Observations),
    {ok, #{result := Result}} =
        quod_applied_certificate:operation_certificate_binding(Certificate),
    Verdict = case Result of applied -> committed; {rejected, _} -> Result end,
    {Target, {Verdict, Ref}}.

-spec completion(operation()) -> pending | {ok, #transaction{}}.
completion(#{origin := Origin, operation_ref := Ref, request_digest := Digest,
             refs := Refs, observations := Observations} = Operation) ->
    case results(Operation) of
        pending -> pending;
        {ok, _} ->
            Rows = [{quod_operation_vector:target(R),
                     {certified, R, maps:get(certificate,
                        maps:get(quod_operation_vector:target(R), Observations))}} || R <- Refs],
            Pairs = [begin
                #{reference := CertifiedRef, evidence := #{transaction := Tx}} =
                    maps:get(quod_operation_vector:target(R), Observations),
                {CertifiedRef, Tx}
            end || R <- Refs],
            {ok, quod_transaction:attach_receipt_evidence(
                   quod_transaction:remote_complete(Origin, Ref, Digest, Rows), Pairs)}
    end.

-doc "Classify one exact application against the owner's durable outcome snapshot.".
-spec applied_result(quod_dtx:certified_ref(), map(), map() | not_ready) ->
          {ok, applied | {rejected, atom()}} | pending | invalid.
applied_result(_Ref, _Evidence, not_ready) -> pending;
applied_result(Ref,
  #{identity := {Ns, Anchor} = Target, phase := transaction,
    slot := Slot, block_hash := BlockHash,
    transaction := #transaction{tx_id = TxId,
      role = {remote_application, _, _, _}}},
  #{applied_floor := Floor, outcome := Outcome})
  when is_integer(Floor), Floor >= 0 ->
    case quod_dtx:certified_ref_claim(Ref) of
        {ok, {Target, Slot, BlockHash, TxId}} when Floor < Slot -> pending;
        {ok, {Target, Slot, BlockHash, TxId}} ->
            case Outcome of
                #{ref := {transaction, Ns, Anchor, TxId},
                  height := Slot, status := committed} -> {ok, applied};
                #{ref := {transaction, Ns, Anchor, TxId},
                  height := Slot, status := rejected, reason := Reason} ->
                    Result = {rejected, Reason},
                    case quod_applied_certificate:valid_operation_result(Result) of
                        true -> {ok, Result};
                        false -> invalid
                    end;
                _ -> invalid
            end;
        _ -> invalid
    end;
applied_result(_, _, _) -> invalid.
