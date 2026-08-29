-module(quod_read_certificate).
-moduledoc """
Portable `f + 1` evidence that one sealed read-only plan still validates.

The certificate contains no facts and interprets no Prolog vocabulary.  It
binds the target ontology, distributed proof, opaque plan digest, and one
certified ledger reference fixing the committee whose signatures may count.
Certified-history verification remains owned by `m:quod_foreign_log`; this
module only checks the statement shape and committee signatures it is given.
""".

-include("quod_proof_limits.hrl").

-export([sign/6, verify_vote/7, new/6, binding/1, valid_shape/1, verify/3]).
-export_type([certificate/0]).

-define(CERTIFICATE_VERSION, 2).
-define(VOTE_VERSION, 2).
-define(VOTE_DOMAIN, <<"quod.read.certificate">>).

-type identity() :: {binary(), <<_:256>>}.
-type signed_row() :: {<<_:256>>, <<_:512>>}.
-type certificate() ::
        {quod_read_certificate, 2, identity(), <<_:256>>, <<_:256>>,
         quod_dtx:certified_ref(), <<_:256>>, [signed_row()]}.

-doc "Sign one exact read-certificate statement with a validator identity.".
-spec sign(identity(), <<_:256>>, <<_:256>>, quod_dtx:certified_ref(), <<_:256>>,
           quod_identity:signer()) -> {ok, signed_row()} | error.
sign(Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
     #{pubkey := <<_:256>> = Signer, key := _} = Identity) ->
    case statement(Target, ProofId, PlanDigest, AnchorRef, CommitteeId) of
        {ok, Statement} ->
            case quod_identity:sign(vote_bytes(Statement), Identity) of
                <<_:512>> = Signature -> {ok, {Signer, Signature}};
                _ -> error
            end;
        error -> error
    end;
sign(_Target, _ProofId, _PlanDigest, _AnchorRef, _CommitteeId, _Identity) ->
    error.

-doc "Verify one correlated validator vote before adding it to a certificate.".
-spec verify_vote(identity(), <<_:256>>, <<_:256>>,
                  quod_dtx:certified_ref(), <<_:256>>, <<_:256>>, <<_:512>>) -> boolean().
verify_vote(Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
            Signer, Signature) ->
    case statement(Target, ProofId, PlanDigest, AnchorRef, CommitteeId) of
        {ok, Statement} ->
            quod_identity:verify(Signature, vote_bytes(Statement), Signer);
        error -> false
    end.

-doc "Build the canonical certificate from already-correlated validator votes.".
-spec new(identity(), <<_:256>>, <<_:256>>, quod_dtx:certified_ref(), <<_:256>>,
          [signed_row()]) -> {ok, certificate()} | error.
new(Target, ProofId, PlanDigest, AnchorRef, CommitteeId, Signatures) ->
    Certificate =
        {quod_read_certificate, ?CERTIFICATE_VERSION, Target, ProofId,
         PlanDigest, AnchorRef, CommitteeId, lists:keysort(1, Signatures)},
    case valid_shape(Certificate) of
        true -> {ok, Certificate};
        false -> error
    end.

-doc "Return the exact signed binding without verifying committee authority.".
-spec binding(certificate()) -> {ok, map()} | error.
binding(
  {quod_read_certificate, ?CERTIFICATE_VERSION, Target, ProofId,
   PlanDigest, AnchorRef, CommitteeId, Signatures} = Certificate) ->
    case statement(Target, ProofId, PlanDigest, AnchorRef, CommitteeId) of
        {ok, Statement} ->
            case valid_signatures(Signatures) andalso
                 erlang:external_size(Certificate) =<
                     ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES of
                true ->
                    {ok, #{target => Target, proof_id => ProofId,
                           plan_digest => PlanDigest,
                           anchor_ref => AnchorRef,
                           committee_id => CommitteeId,
                           statement => Statement,
                           signatures => Signatures}};
                false -> error
            end;
        error -> error
    end;
binding(_Certificate) ->
    error.

-doc "Cheap bounded shape check for an untrusted certificate.".
-spec valid_shape(term()) -> boolean().
valid_shape(Certificate) ->
    case binding(Certificate) of
        {ok, _} -> true;
        error -> false
    end.

-doc "Verify exactly `f + 1` signatures from the certified anchor committee.".
-spec verify(certificate(), [<<_:256>>], <<_:256>>) -> boolean().
verify(Certificate, Committee, CommitteeId) ->
    case {binding(Certificate), quod_quorum:committee_size(Committee)} of
        {{ok, #{committee_id := CommitteeId, statement := Statement,
                signatures := Signatures}},
         {ok, N}} when N > 0 ->
            Needed = quod_dtx_current_view:threshold(N),
            length(Signatures) =:= Needed andalso
                case quod_quorum:sanitize_at_least(
                       Committee, vote_bytes(Statement), Signatures, Needed) of
                    {ok, Signatures} -> true;
                    _ -> false
                end;
        _ -> false
    end.

statement(Target = {Ns, <<_:256>>}, <<_:256>> = ProofId,
          <<_:256>> = PlanDigest, AnchorRef, <<_:256>> = CommitteeId)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    case quod_dtx:certified_ref_binding(AnchorRef) of
        {ok, Target, _Slot, _RecordDigest} ->
            {ok, {quod_read_vote, ?VOTE_VERSION,
                  Target, ProofId, PlanDigest, AnchorRef, CommitteeId}};
        _ -> error
    end;
statement(_Target, _ProofId, _PlanDigest, _AnchorRef, _CommitteeId) ->
    error.

vote_bytes(Statement) ->
    term_to_binary({?VOTE_DOMAIN, Statement}, [deterministic]).

valid_signatures([_ | _] = Signatures) ->
    quod_quorum:valid_signature_list(Signatures, ?MAX_VALIDATORS) andalso
        Signatures =:= lists:ukeysort(1, Signatures);
valid_signatures(_) ->
    false.
