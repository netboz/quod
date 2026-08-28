-module(quod_quorum).
-moduledoc """
Shared bounded verification for signatures made by a certified validator set.

This module knows only committee membership, quorum arithmetic, and Ed25519
signatures. Consensus certificates and proof-scoped agent identity use
the same rules without sharing either protocol's statement format.
""".

-include("quod_ingress_limits.hrl").

-export([threshold/1, committee_size/1, valid_signature_list/2,
         sanitize/3, sanitize_at_least/4, verify/3]).

-type node_key() :: <<_:256>>.
-type signature() :: <<_:512>>.
-type signed_row() :: {node_key(), signature()}.

-spec threshold(pos_integer()) -> pos_integer().
threshold(N) when is_integer(N), N >= 1 ->
    N - (N - 1) div 3.

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
            sanitize_at_least(Committee, Bytes, Signatures, threshold(N));
        _ ->
            error
    end;
sanitize(_Committee, _Bytes, _Signatures) ->
    error.

-doc "Return valid member signatures when the caller's protocol threshold is met.".
-spec sanitize_at_least(term(), binary(), term(), pos_integer()) ->
          {ok, [signed_row()]} | error.
sanitize_at_least(Committee, Bytes, Signatures, Needed)
  when is_binary(Bytes), is_integer(Needed), Needed > 0 ->
    case committee_size(Committee) of
        {ok, N} when N >= Needed ->
            case bounded_signatures(Signatures, N) of
                true ->
                    Members = ordsets:from_list(Committee),
                    Valid = lists:ukeysort(
                              1,
                              [{Signer, Signature}
                               || {Signer, Signature} <- Signatures,
                                  ordsets:is_element(Signer, Members),
                                  quod_identity:verify(
                                    Signature, Bytes, Signer)]),
                    case length(Valid) >= Needed of
                        true -> {ok, Valid};
                        false -> error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    end;
sanitize_at_least(_Committee, _Bytes, _Signatures, _Needed) ->
    error.

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
