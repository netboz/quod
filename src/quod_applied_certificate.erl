-module(quod_applied_certificate).
-moduledoc """
Portable attestations of exact, durably published application outcomes.

One pure certificate family, no collector or process. Finalize statements keep
their existing bytes. Operation statements bind the exact target application
occurrence and canonical outcome under a different signature domain. The
caller supplies already-verified historical entry/committee evidence; routes,
current views and inclusion without an outcome are never verdict authority.
The owning Simplex must establish local durable publication before signing.
""".

-include("quod_proof_limits.hrl").
-include("quod_ledger.hrl").

-export([sign_applied_vote/8, verify_applied_certificate/3,
         valid_applied_certificate_shape/1, applied_certificate_binding/1,
         applied_certificate/2, applied_vote_valid/9, exact_finalize_binding/2,
         operation_statement/3, sign_operation_vote/2,
         verify_operation_vote/3, operation_certificate/2,
         operation_certificate_binding/1, verify_operation_certificate/3,
         valid_operation_result/1, operation_statement_binding/1]).
-export_type([applied_certificate/0, operation_certificate/0]).

-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(APPLIED_CERTIFICATE_VERSION, 1).
-define(APPLIED_VOTE_VERSION, 1).

-type identity() :: {binary(), <<_:256>>}.
-type applied_certificate() ::
        {quod_dtx_applied_certificate, 1, <<_:256>>, identity(), <<_:256>>,
         <<_:256>>, quod_dtx:certified_ref(), non_neg_integer(),
         commit | abort, [{<<_:256>>, <<_:512>>}]}.
-type operation_certificate() ::
        {quod_operation_applied_certificate, 1, tuple(),
         [{<<_:256>>, <<_:512>>}]}.

-doc "Sign one exact Finalize-applied vote with a validator's node identity.".
-spec sign_applied_vote(<<_:256>>, identity(), <<_:256>>, <<_:256>>,
                        quod_dtx:certified_ref(), non_neg_integer(),
                        commit | abort, quod_identity:signer()) ->
          {ok, {<<_:256>>, <<_:512>>}} | error.
sign_applied_vote(NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
                  Generation, Verdict,
                  #{pubkey := <<_:256>> = Signer, key := _} = Identity) ->
    case applied_statement(
           NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
           Generation, Verdict) of
        {ok, Statement} ->
            Signature = quod_identity:sign(
                          applied_vote_bytes(Statement), Identity),
            case Signature of
                <<_:512>> -> {ok, {Signer, Signature}};
                _ -> error
            end;
        error ->
            error
    end;
sign_applied_vote(_NetworkIdentity, _Target, _CommitteeId, _GroupId,
                  _FinalizeRef, _Generation, _Verdict, _Identity) ->
    error.

-doc "Return the exact statement carried by a bounded applied certificate.".
-spec applied_certificate_binding(applied_certificate()) -> {ok, map()} | error.
applied_certificate_binding(
  {quod_dtx_applied_certificate, ?APPLIED_CERTIFICATE_VERSION,
   <<_:256>> = NetworkIdentity, Target, <<_:256>> = CommitteeId,
   <<_:256>> = GroupId, FinalizeRef, Generation, Verdict, Signatures}
  = Certificate) ->
    case applied_statement(
           NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
           Generation, Verdict) of
        {ok, Statement} ->
            {ok, Target, AppliedThrough, _Digest} =
                quod_dtx:certified_ref_binding(FinalizeRef),
            case valid_applied_signatures(Signatures) andalso
                 erlang:external_size(Certificate) =<
                     ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES of
                true ->
                    {ok, #{network_identity => NetworkIdentity,
                           target => Target, committee_id => CommitteeId,
                           group_id => GroupId, finalize_ref => FinalizeRef,
                           applied_through => AppliedThrough,
                           generation => Generation, verdict => Verdict,
                           statement => Statement,
                           signatures => Signatures}};
                false -> error
            end;
        error -> error
    end;
applied_certificate_binding(_Certificate) ->
    error.

-doc "Cheap bounded shape check for an untrusted applied certificate.".
-spec valid_applied_certificate_shape(term()) -> boolean().
valid_applied_certificate_shape(Certificate) ->
    case applied_certificate_binding(Certificate) of
        {ok, _} -> true;
        error -> false
    end.

-doc "Verify one certificate against the exact certified Finalize evidence.".
-spec verify_applied_certificate(applied_certificate(), <<_:256>>, map()) ->
          boolean().
verify_applied_certificate(Certificate, NetworkIdentity,
                           #{identity := Target,
                             committee := Committee,
                             committee_id := CommitteeId} = Evidence) ->
    case applied_certificate_binding(Certificate) of
        {ok, #{network_identity := NetworkIdentity,
               target := Target, committee_id := CommitteeId,
               group_id := GroupId, finalize_ref := FinalizeRef,
               generation := Generation, verdict := Verdict,
               statement := Statement, signatures := Signatures}} ->
            case exact_finalize_binding(Evidence, FinalizeRef) of
                {ok, GroupId, FinalizeRef, Generation, Verdict} ->
                    verify_signatures(Statement, Signatures, Committee);
                _ ->
                    false
            end;
        _ ->
            false
    end;
verify_applied_certificate(_Certificate, _NetworkIdentity, _Evidence) ->
    false.

exact_finalize_binding(
  #{identity := Target, phase := finalize, control := Control,
    entry := Entry}, FinalizeRef) ->
    %% Certified-history verification owns proof authority.  The applied
    %% certificate and this replica's entry may carry different valid quorum
    %% subsets, but both must name one immutable Finalize claim.
    case {quod_dtx:control_kind(Control),
          quod_dtx:recovery_phase(quod_dtx:control_body(Control)),
          quod_dtx:certified_entry_ref(Target, Entry, Control)} of
        {finalize,
         {ok, #{kind := finalize, group_id := <<_:256>> = GroupId,
                generation := Generation, verdict := Verdict}},
         {ok, EntryRef}}
          when is_integer(Generation), Generation >= 0,
               Generation =< ?MAX_UINT64,
               (Verdict =:= commit orelse Verdict =:= abort) ->
            case quod_dtx:same_certified_ref(EntryRef, FinalizeRef) of
                true ->
                    {ok, GroupId, FinalizeRef, Generation, Verdict};
                false ->
                    error
            end;
        _ -> error
    end;
exact_finalize_binding(_Evidence, _FinalizeRef) ->
    error.

applied_certificate(
  {NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
   Generation, Verdict}, Signatures) ->
    Certificate =
        {quod_dtx_applied_certificate, ?APPLIED_CERTIFICATE_VERSION,
         NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
         Generation, Verdict, Signatures},
    case valid_applied_certificate_shape(Certificate) of
        true -> {ok, Certificate};
        false -> retry
    end.

applied_statement(NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
                  Generation, Verdict)
  when is_binary(NetworkIdentity), byte_size(NetworkIdentity) =:= 32,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64,
       (Verdict =:= commit orelse Verdict =:= abort) ->
    case {valid_identity(Target), quod_dtx:certified_ref_binding(FinalizeRef)} of
        {true, {ok, Target, _Slot, _Digest}}
          when is_binary(CommitteeId), byte_size(CommitteeId) =:= 32,
               is_binary(GroupId), byte_size(GroupId) =:= 32 ->
            {ok, {quod_dtx_applied_vote, ?APPLIED_VOTE_VERSION,
                  NetworkIdentity, Target, CommitteeId, GroupId,
                  FinalizeRef, Generation, Verdict}};
        _ -> error
    end;
applied_statement(_NetworkIdentity, _Target, _CommitteeId, _GroupId,
                  _FinalizeRef, _Generation, _Verdict) ->
    error.

applied_vote_bytes(Statement) ->
    term_to_binary(Statement, [deterministic]).

applied_vote_valid(NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
                   Generation, Verdict, Signer, Signature) ->
    case applied_statement(
           NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
           Generation, Verdict) of
        {ok, Statement} ->
            quod_identity:verify(
              Signature, applied_vote_bytes(Statement), Signer);
        error -> false
    end.

valid_applied_signatures([_ | _] = Signatures) ->
    quod_quorum:valid_signature_list(Signatures, ?MAX_VALIDATORS) andalso
        Signatures =:= lists:ukeysort(1, Signatures);
valid_applied_signatures(_) ->
    false.


-doc "Build an exact result statement from an already-verified application entry.".
-spec operation_statement(<<_:256>>, map(), term()) -> {ok, tuple()} | error.
operation_statement(
  <<_:256>> = Network,
  #{identity := Target, phase := transaction, slot := Slot,
    block_hash := <<_:256>> = EntryDigest, committee_id := <<_:256>> = CommitteeId,
    transaction := #transaction{tx_id = <<_:256>> = TxId,
      role = {remote_application, ClaimRef, OperationRef, <<_:256>>}}}, Result) ->
    Statement = {quod_operation_applied_vote, 1, Network, Target, CommitteeId,
                 OperationRef, ClaimRef, {TxId, Slot, EntryDigest}, Result},
    case operation_statement_binding(Statement) of
        {ok, _} -> {ok, Statement};
        error -> error
    end;
operation_statement(_, _, _) -> error.

-doc "Sign after the caller has checked its exact durably published outcome.".
-spec sign_operation_vote(tuple(), quod_identity:signer()) ->
          {ok, {<<_:256>>, <<_:512>>}} | error.
sign_operation_vote(Statement, #{pubkey := <<_:256>> = Signer, key := _} = Identity) ->
    case operation_statement_binding(Statement) of
        {ok, _} ->
            Signature = quod_identity:sign(applied_vote_bytes(Statement), Identity),
            {ok, {Signer, Signature}};
        error -> error
    end;
sign_operation_vote(_, _) -> error.

-spec verify_operation_vote(tuple(), <<_:256>>, <<_:512>>) -> boolean().
verify_operation_vote(Statement, <<_:256>> = Signer, <<_:512>> = Signature) ->
    operation_statement_binding(Statement) =/= error andalso
        quod_identity:verify(Signature, applied_vote_bytes(Statement), Signer);
verify_operation_vote(_, _, _) -> false.

-spec operation_certificate(tuple(), list()) ->
          {ok, operation_certificate()} | error.
operation_certificate(Statement, Signatures) ->
    Certificate = {quod_operation_applied_certificate, 1, Statement, Signatures},
    case operation_certificate_binding(Certificate) of
        {ok, _} -> {ok, Certificate};
        error -> error
    end.

-spec operation_certificate_binding(term()) -> {ok, map()} | error.
operation_certificate_binding(
  {quod_operation_applied_certificate, 1, Statement, Signatures} = Certificate) ->
    case operation_statement_binding(Statement) of
        {ok, Binding} ->
            case valid_applied_signatures(Signatures) andalso
                 erlang:external_size(Certificate) =< ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES of
                true -> {ok, Binding#{statement => Statement, signatures => Signatures}};
                false -> error
            end;
        error -> error
    end;
operation_certificate_binding(_) -> error.

-spec verify_operation_certificate(term(), <<_:256>>, map()) -> boolean().
verify_operation_certificate(Certificate, Network, #{committee := Committee} = Evidence) ->
    case operation_certificate_binding(Certificate) of
        {ok, #{statement := Statement, result := Result, signatures := Signatures}} ->
            operation_statement(Network, Evidence, Result) =:= {ok, Statement} andalso
                verify_signatures(Statement, Signatures, Committee);
        error -> false
    end;
verify_operation_certificate(_, _, _) -> false.

operation_statement_binding(
  {quod_operation_applied_vote, 1, <<_:256>> = Network,
   {Ns, <<_:256>> = Anchor} = Target, <<_:256>> = CommitteeId,
   {operation, SourceNs, <<_:256>> = SourceAnchor, Principal, <<_:256>>} = OperationRef,
   {transaction, SourceNs, SourceAnchor, <<_:256>>} = ClaimRef,
   {<<_:256>> = TxId, Slot, <<_:256>> = EntryDigest}, Result})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(SourceNs), byte_size(SourceNs) > 0,
       is_binary(Principal), byte_size(Principal) > 0,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64 ->
    case valid_operation_result(Result) of
        true -> {ok, #{network_identity => Network, target => Target,
                       committee_id => CommitteeId, operation_ref => OperationRef,
                       claim_ref => ClaimRef, application_ref => {transaction, Ns, Anchor, TxId},
                       slot => Slot, entry_digest => EntryDigest, result => Result}};
        false -> error
    end;
operation_statement_binding(_) -> error.

-spec valid_operation_result(term()) -> boolean().
valid_operation_result(applied) -> true;
valid_operation_result({rejected, Reason}) ->
    lists:member(Reason, [signer_not_admitted, conflict_retry, policy_self_seal_forbidden,
                         invalid_membership, not_authorized]);
valid_operation_result(_) -> false.

verify_signatures(Statement, Signatures, Committee) ->
    case quod_quorum:committee_size(Committee) of
        {ok, N} when N > 0 ->
            Needed = applied_threshold(N),
            length(Signatures) =:= Needed andalso
                quod_quorum:sanitize_at_least(
                  Committee, applied_vote_bytes(Statement), Signatures, Needed) =:=
                    {ok, Signatures};
        _ -> false
    end.

applied_threshold(N) -> N - quod_quorum:threshold(N) + 1.

valid_identity({Ns, <<_:256>>}) -> is_binary(Ns) andalso byte_size(Ns) > 0;
valid_identity(_) -> false.
