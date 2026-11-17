-module(quod_quorum).
-moduledoc """
Shared bounded verification for signatures made by a certified validator set.

This module knows only committee membership, quorum arithmetic, and Ed25519
signatures. Consensus, exact `f + 1` read/application certificates and
proof-scoped agent identity share these rules, not their statement formats.
""".

-include("quod_ingress_limits.hrl").

-export([threshold/1, honest_threshold/1, verify_honest/3,
         committee_size/1, valid_signature_list/2, canonical_signatures/1,
         sanitize/3, verify/3]).

-type node_key() :: <<_:256>>.
-type signature() :: <<_:512>>.
-type signed_row() :: {node_key(), signature()}.

-spec threshold(pos_integer()) -> pos_integer().
threshold(N) when is_integer(N), N >= 1 ->
    N - (N - 1) div 3.

-doc "Minimum signatures guaranteeing one honest signer in a certified committee (`f + 1`).".
-spec honest_threshold(pos_integer()) -> pos_integer().
honest_threshold(N) when is_integer(N), N >= 1 ->
    N - threshold(N) + 1.

-doc "Verify exactly `f + 1` sorted, distinct member signatures over a protocol statement.".
-spec verify_honest(term(), binary(), term()) -> boolean().
verify_honest(Committee, Bytes, Signatures) ->
    case committee_size(Committee) of
        {ok, N} when N > 0 ->
            Needed = honest_threshold(N),
            valid_signature_list(Signatures, Needed) andalso
                length(Signatures) =:= Needed andalso
                sanitize_at_least(Committee, Bytes, Signatures, Needed) =:= {ok, Signatures};
        _ -> false
    end.

-spec committee_size(term()) -> {ok, non_neg_integer()} | error.
committee_size(Committee) ->
    committee_size(Committee, 0, #{}).

committee_size([], Count, _Seen) -> {ok, Count};
committee_size([<<_:256>> = Key | Rest], Count, Seen)
  when Count < ?MAX_VALIDATORS ->
    case maps:is_key(Key, Seen) of
        false -> committee_size(Rest, Count + 1, Seen#{Key => true});
        true -> error
    end;
committee_size(_MalformedDuplicateOrTooLarge, _Count, _Seen) ->
    error.

-doc "Return the sorted, distinct, valid current-member signatures.".
-spec sanitize(term(), binary(), term()) -> {ok, [signed_row()]} | error.
sanitize(Committee, Bytes, Signatures) when is_binary(Bytes) ->
    case committee_size(Committee) of
        {ok, N} when N > 0 ->
            case bounded_signatures(Signatures, N) of
                true -> sanitize_at_least(Committee, Bytes, Signatures, threshold(N));
                false -> error
            end;
        _ ->
            error
    end;
sanitize(_Committee, _Bytes, _Signatures) ->
    error.

%% Both policies validated the committee and bounded every signature row.
%% The exact-honest policy uses Needed as its bound; consensus uses N.
-spec sanitize_at_least([node_key()], binary(), [signed_row()], pos_integer()) ->
          {ok, [signed_row()]} | error.
sanitize_at_least(Committee, Bytes, Signatures, Needed) when is_binary(Bytes) ->
    Members = ordsets:from_list(Committee),
    Valid = lists:ukeysort(
              1,
              [{Signer, Signature}
               || {Signer, Signature} <- Signatures,
                  ordsets:is_element(Signer, Members),
                  quod_identity:verify(Signature, Bytes, Signer)]),
    case length(Valid) >= Needed of
        true -> {ok, Valid};
        false -> error
    end;
sanitize_at_least(_Committee, _Bytes, _Signatures, _Needed) ->
    error.

-doc "Check a nonempty bounded certificate signature list, sorted by distinct signer.".
-spec canonical_signatures(term()) -> boolean().
canonical_signatures([_ | _] = Signatures) ->
    valid_signature_list(Signatures, ?MAX_VALIDATORS) andalso
        Signatures =:= lists:ukeysort(1, Signatures);
canonical_signatures(_) -> false.

-spec valid_signature_list(term(), non_neg_integer()) -> boolean().
valid_signature_list(Signatures, Maximum) when is_integer(Maximum), Maximum >= 0 ->
    bounded_signatures(Signatures, Maximum);
valid_signature_list(_Signatures, _Maximum) ->
    false.

-spec verify(term(), binary(), term()) -> boolean().
verify(Committee, Bytes, Signatures) ->
    case sanitize(Committee, Bytes, Signatures) of
        {ok, _} -> true;
        error -> false
    end.

bounded_signatures([], _Remaining) -> true;
bounded_signatures(
  [{<<_:256>>, <<_:512>>} | Rest], Remaining) when Remaining > 0 ->
    bounded_signatures(Rest, Remaining - 1);
bounded_signatures(_MalformedOrTooLong, _Remaining) -> false.
