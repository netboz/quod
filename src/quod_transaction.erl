-module(quod_transaction).
-moduledoc """
Canonical transaction identity and author signatures.

The signature format is a protocol contract with one fixed domain/schema tag,
bound to the target's `{Ns, GenesisAnchor, AuthorAdmission}` supplied by the
validating committee from its own state — never by the author. The anchor
is the slot-1 block hash and cryptographically covers the per-founding random
`consensus_incarnation` fact committed inside that block, so a transaction
signed under any earlier founding of the same namespace is unverifiable after
a re-found: exact mutation-version read tokens (unlike the old content hashes)
could validate by coincidence across a wipe, and this binding is what closes
that. Every committed field except `sig` is covered; no alternate tag is
accepted.
""".

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([from_plan/5, bind_id/2, valid_id/2,
         plan_outcome_ref/4, encode_durable_submission/2,
         bytes/2, sign/3, sign_submission/3, verify/2,
         submission/2, submission_id/1, verify_submission/1,
         relay_attempt_id/5, decode_verified_submission/2,
         decode_submission_metadata/1,
         validate_request/4, request_claim/1,
         requires_network_identity/1]).

-export_type([target_binding/0]).

-define(DOMAIN, quod_transaction).
-define(ID_DOMAIN, quod_semantic_transaction).
-define(ID_VERSION, 5).
%% V9 binds an author's continuous admission generation, signed-user request,
%% authorization transcript, and the atom-bearing diff/read set through the
%% bounded Prolog wire alphabet, including explicit event occurrences. The
%% fixed envelope can therefore be decoded
%% safely before a small, explicit
%% vocabulary allocation is permitted for an authenticated committee author.
%% Unrelated committee changes do not invalidate retained custody, while
%% remove/re-admit makes every signature from the earlier admission
%% unverifiable. DTX controls use their own admission-scoped sequence lane, and
%% each committed control's certified reference binds the exact committee that
%% finalized its ledger position.
-define(VERSION, 9).
-define(RELAY_ATTEMPT_DOMAIN, quod_relay_attempt).
-define(RELAY_ATTEMPT_VERSION, 1).
-define(PUBKEY_BYTES, 32).
-define(SIGNATURE_BYTES, 64).
-define(SUBMISSION_ID_BYTES, 16).
-define(COMMITTEE_ID_BYTES, 32).
-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).
-define(MAX_CANONICAL_BYTES, (256 * 1024)).

-type target_binding() :: {binary(), binary(), binary()}.

-doc """
Build the unsigned semantic transaction carried by one sealed plan.

`Material` must be the canonical result returned by `quod_dtx:material/1`;
this is what makes the origin's opaque-byte id and validators' decoded-term id
identical.
""".
-spec from_plan(quod_dtx:plan(), map(), binary(), binary(),
                none | quod_client_goal:request_auth()) -> #transaction{}.
from_plan(Plan, #{diff := Diff, read_check := ReadCheck,
                  effects := Effects} = Material,
          GoalBlob, ResultBlob, RequestAuth)
  when is_list(Diff), is_map(ReadCheck),
       is_binary(GoalBlob), is_binary(ResultBlob) ->
    Target = quod_dtx:target(Plan),
    {StoredAuth, AuthTranscript} =
        request_fields(Plan, Material, GoalBlob, RequestAuth),
    Transaction =
        #transaction{tx_id = <<>>,
                     origin = quod_dtx:origin(Plan),
                     proof_id = quod_dtx:proof_id(Plan),
                     plan_digest = quod_dtx:digest(Plan),
                     goal = GoalBlob,
                     result = ResultBlob,
                     diff = Diff,
                     read_check = ReadCheck,
                     effects = Effects,
                     request_auth = StoredAuth,
                     auth_transcript = AuthTranscript,
                     author = none,
                     sig = none},
    Transaction#transaction{
      tx_id = semantic_plan_id(
                Target, Plan, GoalBlob, ResultBlob,
                StoredAuth, AuthTranscript)}.

-doc "Bind a transaction's stable id to its target and complete semantic write.".
-spec bind_id({binary(), binary()}, #transaction{}) -> #transaction{}.
bind_id(Target, Transaction = #transaction{}) ->
    case semantic_id(Target, Transaction) of
        {ok, TxId} -> Transaction#transaction{tx_id = TxId};
        error -> error(bad_transaction_material)
    end.

-doc "Whether `tx_id` is the canonical id of this target-bound semantic write.".
-spec valid_id({binary(), binary()}, #transaction{}) -> boolean().
valid_id({Ns, <<_:256>>} = Target,
         #transaction{tx_id = <<_:256>> = TxId} = Transaction)
  when is_binary(Ns) ->
    semantic_id(Target, Transaction) =:= {ok, TxId};
valid_id(_Target, _Transaction) ->
    false.

-doc "Build the expected anchored outcome without decoding a foreign plan's payloads.".
-spec plan_outcome_ref(quod_dtx:plan(), binary(), binary(),
                       none | quod_client_goal:request_auth()) ->
          {transaction, binary(), binary(), binary()}.
plan_outcome_ref(Plan, GoalBlob, ResultBlob, RequestAuth)
  when is_binary(GoalBlob), is_binary(ResultBlob) ->
    {Ns, <<_:256>> = Anchor} = Target = quod_dtx:target(Plan),
    {StoredAuth, AuthTranscript} =
        request_outcome_fields(Plan, GoalBlob, RequestAuth),
    {transaction, Ns, Anchor,
     semantic_plan_id(
       Target, Plan, GoalBlob, ResultBlob, StoredAuth, AuthTranscript)}.

request_outcome_fields(Plan, _GoalBlob, none) ->
    case quod_dtx:request_binding(Plan) of
        none -> {none, none};
        _ -> error(bad_request_binding)
    end;
request_outcome_fields(Plan, GoalBlob, RequestAuth) ->
    case quod_dtx:material(Plan) of
        {ok, Material} -> request_fields(Plan, Material, GoalBlob, RequestAuth);
        {error, _} -> error(bad_plan)
    end.

-doc "Encode one durable goal/result pair through the shared persistence codec.".
-spec encode_durable_submission(term(), map()) ->
          {ok, binary(), binary()} | {error, term()}.
encode_durable_submission(Goal, Bindings) when is_map(Bindings) ->
    case quod_durable_term:encode_goal(Goal) of
        {ok, GoalBlob} ->
            case quod_durable_term:encode_result(Bindings) of
                {ok, ResultBlob} -> {ok, GoalBlob, ResultBlob};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
encode_durable_submission(_Goal, _Bindings) ->
    {error, invalid_result}.

request_fields(Plan, _Material, _GoalBlob, none) ->
    case quod_dtx:request_binding(Plan) of
        none -> {none, none};
        _ -> error(bad_request_binding)
    end;
request_fields(Plan, #{transcript := Transcript}, GoalBlob,
               {user_goal_v1, <<_:256>> = Digest, _Bytes, _Signature} = Auth) ->
    case quod_dtx:request_binding(Plan) of
        {user_goal_v1, Digest} ->
            Target = quod_dtx:target(Plan),
            case quod_client_goal:authorization_transcript(
                   Transcript, Target, GoalBlob) of
                {ok, Authorization} ->
                    case request_evidence(
                           Target, GoalBlob, Auth, Authorization, verify) of
                        {ok, _Evidence} -> {Auth, Authorization};
                        {error, _} -> error(bad_request_binding)
                    end;
                _ -> error(bad_request_binding)
            end;
        _ ->
            error(bad_request_binding)
    end;
request_fields(_Plan, _Material, _GoalBlob, _RequestAuth) ->
    error(bad_request_binding).

-doc "Validate and expose one transaction's durable signed-user claim.".
-spec validate_request(binary(), {binary(), <<_:256>>}, non_neg_integer(),
                       #transaction{}) ->
          {ok, none | map()} | {error, term()}.
validate_request(_Network, _Target, _AdmissionMs,
                 #transaction{request_auth = none,
                              auth_transcript = none}) ->
    {ok, none};
validate_request(
  <<_:256>> = Network, {Ns, <<_:256>>} = Target, AdmissionMs,
  #transaction{origin = Target, goal = GoalBlob, request_auth = Auth,
               auth_transcript = {user_goal_v1, TranscriptBlob}})
  when is_binary(Ns), is_integer(AdmissionMs), AdmissionMs >= 0,
       is_binary(GoalBlob), is_binary(TranscriptBlob) ->
    request_evidence(
      Target, GoalBlob, Auth, {user_goal_v1, TranscriptBlob},
      {admission, Network, AdmissionMs});
validate_request(_Network, _Target, _AdmissionMs, #transaction{}) ->
    {error, invalid_request_binding}.

-doc "Return the bounded operation claim without consulting runtime state.".
-spec request_claim(#transaction{}) -> none | {ok, map()} | error.
request_claim(#transaction{request_auth = none, auth_transcript = none}) ->
    none;
request_claim(#transaction{origin = Target, goal = GoalBlob, request_auth = Auth,
                           auth_transcript = {user_goal_v1, TranscriptBlob}})
  when is_binary(GoalBlob), is_binary(TranscriptBlob) ->
    case request_evidence(
           Target, GoalBlob, Auth, {user_goal_v1, TranscriptBlob}, verify) of
        {ok, #{claim := Claim}} -> {ok, Claim};
        {error, _} -> error
    end;
request_claim(#transaction{}) ->
    error.

-doc "Whether a content value must be checked against the network identity.".
-spec requires_network_identity(term()) -> boolean().
requires_network_identity([]) -> false;
requires_network_identity(
  [#transaction{request_auth = none, auth_transcript = none} | Rest]) ->
    requires_network_identity(Rest);
requires_network_identity([#transaction{} | _Rest]) -> true;
requires_network_identity([_Malformed | _Rest]) -> true;
requires_network_identity(_ImproperOrMalformed) -> true.

valid_request_fields(_Target, _GoalBlob, none, none) ->
    true;
valid_request_fields(Target, GoalBlob, Auth, Authorization) ->
    case request_evidence(
           Target, GoalBlob, Auth, Authorization, verify) of
        {ok, _Evidence} -> true;
        {error, _} -> false
    end.

%% One structural verifier feeds transaction construction, signed bytes,
%% claim extraction, and admission-time validation. Callers project the shape
%% they need; none of them reimplements request or transcript checks.
request_evidence(Target, GoalBlob, Auth, Authorization, verify) ->
    checked_request_target(
      Target,
      quod_client_goal:verify_durable_authorization(
        Auth, Authorization, GoalBlob));
request_evidence(Target, GoalBlob, Auth, Authorization,
                 {admission, Network, AdmissionMs}) ->
    checked_request_target(
      Target,
      quod_client_goal:validate_durable_authorization(
        Auth, Authorization, Network, Target, AdmissionMs, GoalBlob)).

checked_request_target(
  {Ns, Anchor},
  {ok, #{evidence :=
             #{request := #{target_namespace := Ns,
                            target_genesis_anchor := Anchor}}}} = Result)
  when is_binary(Ns), is_binary(Anchor) ->
    Result;
checked_request_target(_Target, {ok, _OtherEvidence}) ->
    {error, invalid_request_binding};
checked_request_target(_Target, {error, _} = Error) ->
    Error.

semantic_id({Ns, <<_:256>> = Anchor},
            #transaction{origin = Origin, proof_id = ProofId,
                         plan_digest = PlanDigest, goal = Goal,
                         result = Result, diff = Diff,
                         read_check = ReadCheck, effects = Effects,
                         request_auth = RequestAuth,
                         auth_transcript = AuthTranscript})
  when is_binary(Ns) ->
    case semantic_material_bytes(Diff, ReadCheck, Effects) of
        {ok, DiffBytes, ReadCheckBytes, EffectsBytes} ->
            {ok,
             semantic_id_parts(
               Ns, Anchor, Origin, ProofId, PlanDigest, Goal, Result,
               DiffBytes, ReadCheckBytes, EffectsBytes,
               RequestAuth, AuthTranscript)};
        error ->
            error
    end.

semantic_material_bytes(Diff, ReadCheck, Effects)
  when is_list(Diff), is_map(ReadCheck), is_list(Effects) ->
    case {quod_wire_term:encode_canonical(Diff),
          quod_wire_term:encode_canonical(maps:to_list(ReadCheck)),
          quod_wire_term:encode_canonical(Effects)} of
        {{ok, DiffBytes}, {ok, ReadCheckBytes}, {ok, EffectsBytes}} ->
            {ok, DiffBytes, ReadCheckBytes, EffectsBytes};
        _ ->
            error
    end;
semantic_material_bytes(_Diff, _ReadCheck, _Effects) ->
    error.

semantic_plan_id(
  {Ns, <<_:256>> = Anchor}, Plan, GoalBlob, ResultBlob,
  RequestAuth, AuthTranscript) ->
    semantic_id_parts(
      Ns, Anchor, quod_dtx:origin(Plan), quod_dtx:proof_id(Plan),
      quod_dtx:digest(Plan), GoalBlob, ResultBlob,
      quod_dtx:diff_bytes(Plan), quod_dtx:read_check_bytes(Plan),
      quod_dtx:effects_bytes(Plan), RequestAuth, AuthTranscript).

semantic_id_parts(Ns, Anchor, Origin, ProofId, PlanDigest, Goal, Result,
                  DiffBytes, ReadCheckBytes, EffectsBytes,
                  RequestAuth, AuthTranscript) ->
    crypto:hash(
      sha256,
      term_to_binary(
        {?ID_DOMAIN, ?ID_VERSION, Ns, Anchor, Origin, ProofId,
         PlanDigest, Goal, Result, DiffBytes, ReadCheckBytes, EffectsBytes,
         RequestAuth, AuthTranscript},
        [deterministic])).

-doc "Canonical bytes signed by a transaction author, bound to the target identity.".
-spec bytes(target_binding(), #transaction{}) ->
          {ok, binary()} | {error, bad_term}.
bytes({TargetNs, TargetAnchor, AuthorAdmission},
      #transaction{tx_id = TxId, origin = Origin, proof_id = ProofId,
                   plan_digest = PlanDigest, goal = Goal,
                   result = Result, diff = Diff, read_check = ReadCheck,
                   effects = Effects,
                   request_auth = RequestAuth,
                   auth_transcript = AuthTranscript,
                   author = Author, author_seq = AuthorSeq,
                   submitted_at = SubmittedAt})
  when is_binary(TargetNs), is_binary(TargetAnchor),
       is_binary(AuthorAdmission), byte_size(TargetAnchor) =:= 32,
       byte_size(AuthorAdmission) =:= 32 ->
    case {encode_material(Diff, ReadCheck, Effects),
          valid_request_fields(
            {TargetNs, TargetAnchor}, Goal, RequestAuth, AuthTranscript)} of
        {{ok, MaterialWire, EffectsWire}, true}
          when byte_size(EffectsWire) =< ?QUOD_MAX_DIRECT_EFFECT_BYTES ->
            case quod_effect:validate_transaction(
                   TargetNs, TargetAnchor, Author, Effects) of
                true ->
                    {ok,
                     canonical_bytes(
                       TargetNs, TargetAnchor, AuthorAdmission, TxId, Origin,
                       ProofId, PlanDigest, Goal, Result, MaterialWire,
                       EffectsWire, RequestAuth, AuthTranscript,
                       Author, AuthorSeq, SubmittedAt)};
                false ->
                    {error, bad_term}
            end;
        {{ok, _MaterialWire, _EffectsWire}, _} ->
            {error, bad_term};
        {{error, bad_term} = Error, _} ->
            Error
    end;
bytes(_Binding, _Transaction) ->
    {error, bad_term}.

canonical_bytes(TargetNs, TargetAnchor, AuthorAdmission, TxId, Origin,
                ProofId, PlanDigest, Goal, Result, MaterialWire, EffectsWire,
                RequestAuth, AuthTranscript, Author,
                AuthorSeq, SubmittedAt) ->
    term_to_binary(
      {?DOMAIN, ?VERSION, TargetNs, TargetAnchor, AuthorAdmission,
       TxId, Origin, ProofId, PlanDigest, Goal, Result, MaterialWire,
       EffectsWire, RequestAuth, AuthTranscript,
       Author, AuthorSeq, SubmittedAt},
      [deterministic]).

encode_material(Diff, ReadCheck, Effects)
  when is_list(Diff), is_map(ReadCheck), is_list(Effects) ->
    case {quod_wire_term:encode({Diff, maps:to_list(ReadCheck)}),
          quod_wire_term:encode_canonical(Effects)} of
        {{ok, MaterialWire}, {ok, EffectsWire}} ->
            {ok, MaterialWire, EffectsWire};
        _ ->
            {error, bad_term}
    end;
encode_material(_Diff, _ReadCheck, _Effects) ->
    {error, bad_term}.

-doc """
Sign an unsigned transaction for the target identity. The supplied identity
must own the same public key named by `author`; callers cannot use a node key
to sign for a different author.
""".
-spec sign(target_binding(), #transaction{}, quod_identity:signer()) ->
        {ok, #transaction{}} | {error, term()}.
sign(Binding, Transaction, Identity) ->
    case signing_material(Binding, Transaction, Identity) of
        {ok, Signed, _Author, _Signature, _Canonical} -> {ok, Signed};
        {error, _} = Error -> Error
    end.

-doc "Sign and build a relay submission without encoding the transaction twice.".
-spec sign_submission(target_binding(), #transaction{}, quod_identity:signer()) ->
          {ok, #transaction{}, {submit, binary(), binary(), binary()}} |
          {error, term()}.
sign_submission(Binding, Transaction, Identity) ->
    case signing_material(Binding, Transaction, Identity) of
        {ok, Signed, Author, Signature, Canonical}
          when byte_size(Canonical) =< ?MAX_CANONICAL_BYTES ->
            {ok, Signed, {submit, Author, Signature, Canonical}};
        {ok, _Signed, _Author, _Signature, _Canonical} ->
            {error, too_large};
        {error, _} = Error ->
            Error
    end.

signing_material(
  {TargetNs, TargetAnchor, AuthorAdmission} = Binding,
  #transaction{author = Author, sig = none} = Transaction,
  #{pubkey := Author} = Identity)
  when is_binary(TargetNs), is_binary(TargetAnchor), is_binary(AuthorAdmission),
       byte_size(TargetAnchor) =:= 32, byte_size(AuthorAdmission) =:= 32,
       byte_size(Author) =:= ?PUBKEY_BYTES ->
    case bytes(Binding, Transaction) of
        {ok, Canonical} ->
            Signature = quod_identity:sign(Canonical, Identity),
            {ok, Transaction#transaction{sig = Signature},
             Author, Signature, Canonical};
        {error, _} = Error ->
            Error
    end;
signing_material(_Binding, #transaction{sig = Sig}, _Identity)
  when Sig =/= none ->
    {error, already_signed};
signing_material(_Binding, #transaction{}, _Identity) ->
    {error, author_mismatch};
signing_material(_Binding, _Transaction, _Identity) ->
    {error, malformed_transaction}.

-doc "Verify a transaction signature against the validator's own target identity.".
-spec verify(target_binding(), #transaction{}) -> boolean().
verify({TargetNs, TargetAnchor, AuthorAdmission} = Binding,
       #transaction{author = Author, sig = Signature} = Transaction)
  when is_binary(TargetNs), is_binary(TargetAnchor), is_binary(AuthorAdmission),
       byte_size(TargetAnchor) =:= 32, byte_size(AuthorAdmission) =:= 32,
       is_binary(Author), byte_size(Author) =:= ?PUBKEY_BYTES,
       is_binary(Signature), byte_size(Signature) =:= ?SIGNATURE_BYTES ->
    case bytes(Binding, Transaction) of
        {ok, Canonical} ->
            quod_identity:verify(Signature, Canonical, Author);
        {error, bad_term} ->
            false
    end;
verify(_Binding, _Transaction) ->
    false.

-doc """
Build the relay payload whose canonical transaction bytes remain opaque until
the receiving validator has verified their signature.
""".
-spec submission(target_binding(), #transaction{}) ->
        {ok, {submit, binary(), binary(), binary()}} | {error, term()}.
submission(Binding, #transaction{author = Author, sig = Signature} = Transaction)
  when is_binary(Author), byte_size(Author) =:= ?PUBKEY_BYTES,
       is_binary(Signature), byte_size(Signature) =:= ?SIGNATURE_BYTES ->
    case bytes(Binding, Transaction) of
        {ok, Canonical} when byte_size(Canonical) =< ?MAX_CANONICAL_BYTES ->
            {ok, {submit, Author, Signature, Canonical}};
        {ok, _Canonical} ->
            {error, too_large};
        {error, _} = Error ->
            Error
    end;
submission(_Binding, _Transaction) ->
    {error, unsigned_or_malformed}.

-doc "Stable 16-byte correlation id for one authenticated author/signature pair.".
-spec submission_id({submit, binary(), binary(), binary()}) -> binary().
submission_id({submit, Author, Signature, _Canonical}) ->
    <<Id:16/binary, _/binary>> =
        crypto:hash(
          sha256,
          term_to_binary(
            {quod_submission, 2, Author, Signature}, [deterministic])),
    Id.

-doc """
Return the stable 16-byte identity of one exact relay placement.

The domain-separated digest binds an exact signed submission to its namespace,
committee view, target slot, and target validator. Retargeting the unchanged
submission therefore keeps its `submission_id/1` but receives a distinct attempt
id. Malformed inputs return `error`; this helper is total at the relay boundary.
""".
-spec relay_attempt_id(binary(), binary(), binary(), pos_integer(), binary()) ->
        binary() | error.
relay_attempt_id(Ns, SubmissionId, CommitteeId, TargetSlot, Target)
  when is_binary(Ns),
       is_binary(SubmissionId),
       byte_size(SubmissionId) =:= ?SUBMISSION_ID_BYTES,
       is_binary(CommitteeId),
       byte_size(CommitteeId) =:= ?COMMITTEE_ID_BYTES,
       is_integer(TargetSlot),
       TargetSlot >= 1,
       TargetSlot =< ?MAX_SLOT,
       is_binary(Target),
       byte_size(Target) =:= ?PUBKEY_BYTES ->
    Canonical =
        term_to_binary(
          {?RELAY_ATTEMPT_DOMAIN, ?RELAY_ATTEMPT_VERSION,
           Ns, SubmissionId, CommitteeId, TargetSlot, Target},
          [deterministic]),
    <<Id:?SUBMISSION_ID_BYTES/binary, _/binary>> =
        crypto:hash(sha256, Canonical),
    Id;
relay_attempt_id(_Ns, _SubmissionId, _CommitteeId, _TargetSlot, _Target) ->
    error.

-doc """
Verify the author signature over the still-opaque canonical bytes. This is the
only operation permitted before the inner transaction is decoded.
""".
-spec verify_submission(term()) -> boolean().
verify_submission({submit, Author, Signature, Canonical})
  when is_binary(Author), byte_size(Author) =:= ?PUBKEY_BYTES,
       is_binary(Signature), byte_size(Signature) =:= ?SIGNATURE_BYTES,
       is_binary(Canonical), byte_size(Canonical) =< ?MAX_CANONICAL_BYTES ->
    quod_identity:verify(Signature, Canonical, Author);
verify_submission(_Submission) ->
    false.

-doc """
Decode a submission after `verify_submission/1` succeeded. The re-encode check
rejects non-canonical ETF and binds the opaque bytes to the target identity
and `Author`.
""".
-spec decode_verified_submission(target_binding(), term()) ->
        {ok, #transaction{}} | {error, term()}.
decode_verified_submission(
  {TargetNs, TargetAnchor, AuthorAdmission} = Binding,
  {submit, Author, Signature,
   <<131, 104, 18, _/binary>> = Canonical})
  when is_binary(TargetNs), is_binary(TargetAnchor),
       is_binary(AuthorAdmission),
       is_binary(Author), is_binary(Signature),
       byte_size(Canonical) =< ?MAX_CANONICAL_BYTES ->
    case quod_safe_term:decode(Canonical, ?MAX_CANONICAL_BYTES) of
        {ok,
         {?DOMAIN, ?VERSION, TargetNs, TargetAnchor, AuthorAdmission,
          TxId, Origin, ProofId,
          PlanDigest, Goal, Result, MaterialWire, EffectsWire,
          RequestAuth, AuthTranscript,
          Author, AuthorSeq,
          SubmittedAt}} ->
            case decode_material(MaterialWire, EffectsWire) of
                {ok, Diff, ReadCheck, Effects} ->
                    Transaction =
                        #transaction{tx_id = TxId, origin = Origin,
                                     proof_id = ProofId,
                                     plan_digest = PlanDigest,
                                     goal = Goal, result = Result,
                                     diff = Diff, read_check = ReadCheck,
                                     effects = Effects,
                                     request_auth = RequestAuth,
                                     auth_transcript = AuthTranscript,
                                     author = Author,
                                     author_seq = AuthorSeq,
                                     submitted_at = SubmittedAt,
                                     sig = Signature},
                    case bytes(Binding, Transaction) of
                        {ok, Reencoded} when Reencoded =:= Canonical ->
                            {ok, Transaction};
                        {ok, _OtherCanonical} ->
                            {error, noncanonical};
                        {error, _} -> {error, malformed_material}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {ok, Other}
          when is_tuple(Other), tuple_size(Other) =:= 18,
               element(1, Other) =:= ?DOMAIN,
               element(2, Other) =/= ?VERSION ->
            {error, unsupported_version};
        {ok, _Other} ->
            {error, namespace_or_author_mismatch};
        {error, _Reason} ->
            {error, malformed_canonical_bytes}
    end;
decode_verified_submission(_Binding, _Submission) ->
    {error, malformed_submission}.

-doc "Decode bounded metadata from the one current V9 transaction envelope.".
-spec decode_submission_metadata(term()) ->
          {ok, #{target := {binary(), binary()},
                 admission := binary(), tx_id := binary(),
                 effects := [quod_effect:effect()], author := binary(),
                 sequence := non_neg_integer()}} |
          {error, malformed_submission}.
decode_submission_metadata(Canonical)
  when is_binary(Canonical), byte_size(Canonical) =< ?MAX_CANONICAL_BYTES ->
    case quod_safe_term:decode(Canonical, ?MAX_CANONICAL_BYTES) of
        {ok,
         {?DOMAIN, ?VERSION, Ns, <<_:256>> = Anchor,
          <<_:256>> = Admission, <<_:256>> = TxId,
          _Origin, _ProofId, _PlanDigest, _Goal, _Result,
          _MaterialWire, EffectsWire, _RequestAuth, _AuthTranscript,
          <<_:256>> = Author, Sequence, _SubmittedAt} = Decoded}
          when is_binary(Ns), is_integer(Sequence), Sequence >= 0 ->
            case {term_to_binary(Decoded, [deterministic]) =:= Canonical,
                  quod_wire_term:decode_canonical(
                    EffectsWire, ?QUOD_MAX_DIRECT_EFFECT_BYTES)} of
                {true, {ok, Effects}} when is_list(Effects) ->
                    {ok, #{target => {Ns, Anchor}, admission => Admission,
                           tx_id => TxId, effects => Effects,
                           author => Author, sequence => Sequence}};
                _ ->
                    {error, malformed_submission}
            end;
        _ ->
            {error, malformed_submission}
    end;
decode_submission_metadata(_Canonical) ->
    {error, malformed_submission}.

decode_material(MaterialWire, EffectsWire) ->
    case {quod_wire_term:decode(MaterialWire),
          quod_wire_term:decode_canonical(
            EffectsWire, ?QUOD_MAX_DIRECT_EFFECT_BYTES)} of
        {{ok, {Diff0, ReadPairs0}}, {ok, Effects0}}
          when is_list(Diff0), is_list(ReadPairs0), is_list(Effects0) ->
            case quod_wire_term:materialize_symbols(
                   {Diff0, ReadPairs0, Effects0}) of
                {ok, {Diff, ReadPairs, Effects}} ->
                    ReadCheck = maps:from_list(ReadPairs),
                    case map_size(ReadCheck) =:= length(ReadPairs) andalso
                         quod_effect:validate_list(Effects) of
                        true -> {ok, Diff, ReadCheck, Effects};
                        false -> {error, malformed_material}
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, malformed_material}
    end.
