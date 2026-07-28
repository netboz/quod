-module(quod_transaction).
-moduledoc """
Canonical transaction-author signatures.

The signature format is a protocol contract with one fixed domain/schema tag,
bound to the target ontology supplied by the validating committee. Every
committed transaction field except `sig` is covered; no alternate tag is
accepted.
""".

-include("quod_ledger.hrl").

-export([bytes/2, sign/3, verify/2,
         submission/2, submission_id/1, verify_submission/1,
         relay_attempt_id/5, decode_verified_submission/2]).

-define(DOMAIN, quod_transaction).
-define(VERSION, 2).
-define(RELAY_ATTEMPT_DOMAIN, quod_relay_attempt).
-define(RELAY_ATTEMPT_VERSION, 1).
-define(PUBKEY_BYTES, 32).
-define(SIGNATURE_BYTES, 64).
-define(SUBMISSION_ID_BYTES, 16).
-define(COMMITTEE_ID_BYTES, 32).
-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).
-define(MAX_CANONICAL_BYTES, (256 * 1024)).

-doc "Canonical, namespace-bound bytes signed by a transaction author.".
-spec bytes(binary(), #transaction{}) -> binary().
bytes(TargetNs,
      #transaction{tx_id = TxId, caller_ns = CallerNs, goal = Goal,
                   result = Result, diff = Diff, read_check = ReadCheck,
                   author = Author, author_seq = AuthorSeq,
                   submitted_at = SubmittedAt})
  when is_binary(TargetNs) ->
    term_to_binary(
      {?DOMAIN, ?VERSION, TargetNs, TxId, CallerNs, Goal, Result,
       Diff, ReadCheck, Author, AuthorSeq, SubmittedAt},
      [deterministic]).

-doc """
Sign an unsigned transaction for `TargetNs`. The supplied identity must own the
same public key named by `author`; callers cannot use a node key to sign for a
different author.
""".
-spec sign(binary(), #transaction{}, quod_identity:signer()) ->
        {ok, #transaction{}} | {error, term()}.
sign(TargetNs,
     #transaction{author = Author, sig = none} = Transaction,
     #{pubkey := Author} = Identity)
  when is_binary(TargetNs), byte_size(Author) =:= ?PUBKEY_BYTES ->
    Signature = quod_identity:sign(bytes(TargetNs, Transaction), Identity),
    {ok, Transaction#transaction{sig = Signature}};
sign(_TargetNs, #transaction{sig = Sig}, _Identity) when Sig =/= none ->
    {error, already_signed};
sign(_TargetNs, #transaction{}, _Identity) ->
    {error, author_mismatch};
sign(_TargetNs, _Transaction, _Identity) ->
    {error, malformed_transaction}.

-doc "Verify a transaction signature against the validator's target namespace.".
-spec verify(binary(), #transaction{}) -> boolean().
verify(TargetNs, #transaction{author = Author, sig = Signature} = Transaction)
  when is_binary(TargetNs),
       is_binary(Author), byte_size(Author) =:= ?PUBKEY_BYTES,
       is_binary(Signature), byte_size(Signature) =:= ?SIGNATURE_BYTES ->
    quod_identity:verify(Signature, bytes(TargetNs, Transaction), Author);
verify(_TargetNs, _Transaction) ->
    false.

-doc """
Build the relay payload whose canonical transaction bytes remain opaque until
the receiving validator has verified their signature.
""".
-spec submission(binary(), #transaction{}) ->
        {ok, {submit, binary(), binary(), binary()}} | {error, term()}.
submission(TargetNs, #transaction{author = Author, sig = Signature} = Transaction)
  when is_binary(TargetNs),
       is_binary(Author), byte_size(Author) =:= ?PUBKEY_BYTES,
       is_binary(Signature), byte_size(Signature) =:= ?SIGNATURE_BYTES ->
    Canonical = bytes(TargetNs, Transaction),
    case byte_size(Canonical) =< ?MAX_CANONICAL_BYTES of
        true  -> {ok, {submit, Author, Signature, Canonical}};
        false -> {error, too_large}
    end;
submission(_TargetNs, _Transaction) ->
    {error, unsigned_or_malformed}.

-doc "Stable 16-byte correlation id for one exact signed submission.".
-spec submission_id({submit, binary(), binary(), binary()}) -> binary().
submission_id(Submission) ->
    <<Id:16/binary, _/binary>> =
        crypto:hash(sha256, term_to_binary(Submission, [deterministic])),
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
rejects non-canonical ETF and binds the opaque bytes to `TargetNs` and `Author`.
""".
-spec decode_verified_submission(binary(), term()) ->
        {ok, #transaction{}} | {error, term()}.
decode_verified_submission(
  TargetNs, {submit, Author, Signature,
             <<131, 104, 12, _/binary>> = Canonical})
  when is_binary(TargetNs), is_binary(Author), is_binary(Signature),
       byte_size(Canonical) =< ?MAX_CANONICAL_BYTES ->
    try binary_to_term(Canonical) of
        {?DOMAIN, ?VERSION, TargetNs, TxId, CallerNs, Goal, Result,
         Diff, ReadCheck, Author, AuthorSeq, SubmittedAt} ->
            Transaction =
                #transaction{tx_id = TxId, caller_ns = CallerNs, goal = Goal,
                             result = Result, diff = Diff, read_check = ReadCheck,
                             author = Author, author_seq = AuthorSeq,
                             submitted_at = SubmittedAt,
                             sig = Signature},
            case bytes(TargetNs, Transaction) =:= Canonical of
                true  -> {ok, Transaction};
                false -> {error, noncanonical}
            end;
        _ ->
            {error, namespace_or_author_mismatch}
    catch
        _:_ -> {error, malformed_canonical_bytes}
    end;
decode_verified_submission(_TargetNs, _Submission) ->
    {error, malformed_submission}.
