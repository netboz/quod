-module(quod_common_primitives).
-moduledoc """
Common execution primitives available to every ontology's Prolog.

Two pure helpers with no reality behind them, installed by
`m:quod_committed_projection` next to the action mechanics. They are not
governed bridges (`m:quod_predicates`): neither reads node state, so a plan
that used them stays sealable.

- `'$quod_draw'(+Salt, +N, -I)` — the proof-bound draw. `I` is
  `hmac_sha256(ProofId, canonical(Salt)) mod N`, where `ProofId` is the
  32-byte identity the engine mints before the proof runs and binds into
  every sealed plan and committed transaction. Same proof, same salt, same
  `I`, in the origin worker and in every co-hosted or remote scope of that
  proof; a retried request is a new proof and draws afresh. Fails plainly
  (never errors) when `N` is not a positive integer, `Salt` is not ground,
  the context kind is not `proof`, or the state carries no proof identity
  (verdict re-proofs, bare engines). Ontologies reach it through
  `proof_draw/3` in `common_predicates.pl`. It is deterministic selection:
  neither secure randomness nor a uniqueness guarantee.
- `binary_codes(?Binary, ?Codes)` — a binary and its byte list, either way
  round, so generated text stays a binary and never becomes an atom. Fails
  plainly for anything that is not a binary or a list of bytes.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([load/1, draw_3/3, binary_codes_2/3]).

-define(DRAW, '$quod_draw').
-define(BINARY_CODES, binary_codes).

-doc "Install both primitives into a base engine state.".
-spec load(tuple()) -> tuple().
load(#est{db = Db0} = Est) ->
    Db1 = erlog_int:add_compiled_proc({?DRAW, 3}, ?MODULE, draw_3, Db0),
    Est#est{db = erlog_int:add_compiled_proc(
                   {?BINARY_CODES, 2}, ?MODULE, binary_codes_2, Db1)}.

-spec draw_3(term(), list(), tuple()) -> term().
draw_3({?DRAW, Salt0, N0, I0}, Next, #est{bs = Bs} = St) ->
    Salt = erlog_int:dderef(Salt0, Bs),
    case {erlog_int:deref(N0, Bs), proof_id(St)} of
        {N, {ok, ProofId}} when is_integer(N), N > 0 ->
            case quod_wire_term:is_ground(Salt)
                 andalso quod_wire_term:encode_canonical(Salt) of
                {ok, SaltBytes} ->
                    Mac = crypto:mac(hmac, sha256, ProofId, SaltBytes),
                    erlog_int:unify_prove_body(
                      I0, binary:decode_unsigned(Mac) rem N, Next, St);
                _ ->
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

%% The proof identity lives where the engine put it: the origin worker keeps
%% it in its proof context, a co-hosted or remote scope worker carries it in
%% the session metadata the engine opened the scope with. Content can forge
%% neither. Anything else — no session, a verdict engine — is not a proof.
proof_id(St) ->
    case quod_predicates:ctx_kind(quod_predicates:context(St)) of
        proof ->
            try quod_proof_session:context(St) of
                {origin, _} ->
                    try {ok, quod_proof_context:proof_id()}
                    catch error:no_proof_context -> error
                    end;
                {scope, ProofId, _Origin, _Ref, _ScopeId}
                  when is_binary(ProofId), byte_size(ProofId) =:= 32 ->
                    {ok, ProofId};
                _ ->
                    error
            catch error:badarg -> error
            end;
        _ ->
            error
    end.

-spec binary_codes_2(term(), list(), tuple()) -> term().
binary_codes_2({?BINARY_CODES, Binary0, Codes0}, Next, #est{bs = Bs} = St) ->
    case erlog_int:deref(Binary0, Bs) of
        Binary when is_binary(Binary) ->
            erlog_int:unify_prove_body(
              Codes0, binary_to_list(Binary), Next, St);
        {_} ->
            case erlog_int:dderef(Codes0, Bs) of
                Codes when is_list(Codes) ->
                    case bytes(Codes) of
                        true -> erlog_int:unify_prove_body(
                                  Binary0, list_to_binary(Codes), Next, St);
                        false -> erlog_int:fail(St)
                    end;
                _ ->
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

bytes([Code | Codes]) when is_integer(Code), Code >= 0, Code =< 255 ->
    bytes(Codes);
bytes([]) -> true;
bytes(_) -> false.
