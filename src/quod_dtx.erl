-module(quod_dtx).
-moduledoc """
Durable-transaction artifacts: the signed **local plan** a scope seals.

A local plan is the target-side record of everything one ontology scope
contributed to a distributed proof: its exact staged diff, its exact OCC read
tokens, the bounded invocation transcript, and the identities the plan binds —
sealed and witness-signed by the node that executed the scope. Co-hosted and
remote scopes seal through the same `seal_session/2`; only the transport of the
resulting plan differs.

## Envelope

The wire/memory form is one term:

    {quod_plan, Core, Signer, Signature}

`Core` is a map whose `diff`, `read_check`, and `transcript` values are
**nested deterministic ETF binaries**, not terms. A plan travels target →
origin → (later) back to the target: the origin verifies the signature and the
bounded outer shape but never decodes the nested payloads, so no foreign atom
is ever allocated outside the ontology that owns it. The signature covers
`plan_bytes/1` — the canonical bytes of `{Domain, Version, Core}` — under the
local-plan witness domain.

`Signer`/`Signature` are `none` only on a node booted without an identity
(bare test engines); a keyed node always witnesses its plans. The
**principal** inside `Core` is the origin's engine-owned principal, distinct
from the sealing target's `Signer`.

## Materiality and the live-bridge gate

A scope with an empty diff AND an empty read set seals to `not_material` — it
contributed nothing a commit could depend on. A scope with a **material diff**
that consulted a live reality bridge (`m:quod_predicates` query-class external
predicates) cannot seal: its decisions rest on node-local, non-replayable
state that no later validation can re-prove, so sealing fails
`{non_transactional_dependency, Functor}`. `peer_ready/1` is exempt — its
decision is re-proved by every validator in the membership verdict, so it is
never a hidden dependency of a committed diff.
""".

-include("quod_proof_limits.hrl").

-export([seal_session/2, verify/1, encode/1, decode/1,
         node_signer/0,
         core/1, target/1, base_height/1, proof_id/1, origin/1,
         principal/1, overlay_generation/1, signer/1,
         diff/1, read_check/1, transcript/1]).

-export_type([plan/0, principal/0, transcript_entry/0]).

-define(PLAN_DOMAIN, <<"quod.dtx.plan">>).
-define(PLAN_VERSION, 1).

-type identity() :: quod_proof_context:identity().
-type principal() :: {node, <<_:256>>} | anonymous.
-type transcript_entry() ::
        {<<_:128>>, [identity()], binary(),
         non_neg_integer(), binary(), active | complete | error | cancelled}.
-opaque plan() :: {quod_plan, map(), none | <<_:256>>, none | binary()}.

-doc """
Seal the calling worker's proof session into a signed local plan.

Must run in the session's owner process. `Bind` carries the identities the
plan is bound to: `target`, `base_height`, `proof_id`, `origin`, `principal`.
""".
-spec seal_session(quod_proof_session:session(),
                   #{target := identity(), base_height := non_neg_integer(),
                     proof_id := <<_:256>>, origin := identity(),
                     principal := principal()}) ->
          {ok, plan()} | not_material | {error, term()}.
seal_session(Session,
             #{target := {_TargetNs, <<_:256>>} = Target,
               base_height := BaseHeight,
               proof_id := <<_:256>> = ProofId,
               origin := {_OriginNs, <<_:256>>} = Origin,
               principal := Principal})
  when is_integer(BaseHeight), BaseHeight >= 0 ->
    true = valid_principal(Principal),
    Diff = quod_proof_session:local_changes(Session),
    ReadCheck = quod_proof_session:read_set(Session),
    case {Diff, map_size(ReadCheck)} of
        {[], 0} ->
            not_material;
        _ ->
            seal_material(
              Session, Target, BaseHeight, ProofId, Origin, Principal,
              Diff, ReadCheck)
    end.

seal_material(Session, Target, BaseHeight, ProofId, Origin, Principal,
              Diff, ReadCheck) ->
    Bridges = quod_proof_session:live_bridges(Session),
    {Transcript, Generation} = quod_proof_session:transcript(Session),
    case seal_admissible(Diff, ReadCheck, Bridges) of
        ok ->
            Core = #{target => Target,
                     base_height => BaseHeight,
                     proof_id => ProofId,
                     origin => Origin,
                     principal => Principal,
                     overlay_generation => Generation,
                     diff => deterministic(Diff),
                     read_check => deterministic(ReadCheck),
                     transcript => deterministic(Transcript)},
            sign_core(Core);
        {error, _} = Error ->
            Error
    end.

%% A material diff must not rest on live-bridge truth (module doc); the plan
%% itself must fit the network's fixed bounds before any signature is minted.
seal_admissible(Diff, ReadCheck, Bridges) ->
    case {Diff, Bridges} of
        {[_ | _], [Functor | _]} ->
            {error, {non_transactional_dependency, Functor}};
        _ ->
            case {length(Diff) =< ?QUOD_MAX_PLAN_DIFF_OPS,
                  map_size(ReadCheck) =< ?QUOD_MAX_PLAN_READ_FUNCTORS} of
                {true, true} -> ok;
                {false, _} -> {error, {too_large, plan}};
                {_, false} -> {error, {too_large, plan}}
            end
    end.

sign_core(Core) ->
    Bytes = plan_bytes(Core),
    Plan =
        case node_signer() of
            {ok, #{pubkey := Signer} = Identity} ->
                {quod_plan, Core, Signer,
                 quod_identity:sign(Bytes, Identity)};
            none ->
                {quod_plan, Core, none, none}
        end,
    case byte_size(deterministic(Plan)) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES of
        true -> {ok, Plan};
        false -> {error, {too_large, plan}}
    end.

plan_bytes(Core) ->
    deterministic({?PLAN_DOMAIN, ?PLAN_VERSION, Core}).

deterministic(Term) ->
    term_to_binary(Term, [deterministic]).

-doc "This node's witness identity, or `none` on a node booted without keys.".
-spec node_signer() -> {ok, quod_identity:signer()} | none.
node_signer() ->
    case {application:get_env(quod, node_pubkey),
          application:get_env(quod, identity_key)} of
        {{ok, <<_:256>> = Pubkey}, {ok, Key}} ->
            {ok, #{pubkey => Pubkey, key => Key}};
        _ ->
            none
    end.

-doc """
Whether a plan's witness signature matches its canonical bytes.

An unsigned plan (`Signer = none`) verifies only as unsigned; whether an
unsigned plan is *acceptable* is the consumer's policy, not this check.
""".
-spec verify(plan()) -> boolean().
verify({quod_plan, Core, none, none}) when is_map(Core) -> true;
verify({quod_plan, Core, <<_:256>> = Signer, Signature})
  when is_map(Core), is_binary(Signature) ->
    quod_identity:verify(Signature, plan_bytes(Core), Signer);
verify(_) ->
    false.

-doc "Encode a plan for the scope wire, enforcing the envelope bound.".
-spec encode(plan()) -> {ok, binary()} | {error, {too_large, plan}}.
encode({quod_plan, _Core, _Signer, _Signature} = Plan) ->
    Encoded = deterministic(Plan),
    case byte_size(Encoded) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES of
        true -> {ok, Encoded};
        false -> {error, {too_large, plan}}
    end.

-doc """
Decode and shape-validate an untrusted plan blob.

Validates the bounded outer envelope only; the nested `diff`, `read_check`,
and `transcript` binaries stay opaque until the ontology that owns their
symbols decodes them (`diff/1`, `read_check/1`, `transcript/1`).
""".
-spec decode(binary()) -> {ok, plan()} | {error, term()}.
decode(Blob) when is_binary(Blob) ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_PLAN_ENVELOPE_BYTES) of
        {ok, {quod_plan, Core, Signer, Signature} = Plan} ->
            case valid_core(Core) andalso valid_witness(Signer, Signature) of
                true -> {ok, Plan};
                false -> {error, {protocol_error, bad_payload}}
            end;
        {ok, _Other} ->
            {error, {protocol_error, bad_payload}};
        {error, too_large} ->
            {error, {too_large, plan}};
        {error, _} ->
            {error, {protocol_error, bad_payload}}
    end;
decode(_Blob) ->
    {error, {protocol_error, bad_payload}}.

valid_core(#{target := Target, base_height := BaseHeight,
             proof_id := ProofId, origin := Origin,
             principal := Principal, overlay_generation := Generation,
             diff := Diff, read_check := ReadCheck,
             transcript := Transcript} = Core)
  when map_size(Core) =:= 9 ->
    valid_identity(Target) andalso valid_identity(Origin) andalso
        is_integer(BaseHeight) andalso BaseHeight >= 0 andalso
        is_binary(ProofId) andalso byte_size(ProofId) =:= 32 andalso
        valid_principal(Principal) andalso
        is_integer(Generation) andalso Generation >= 0 andalso
        is_binary(Diff) andalso is_binary(ReadCheck) andalso
        is_binary(Transcript);
valid_core(_) ->
    false.

valid_witness(none, none) -> true;
valid_witness(<<_:256>>, Signature) -> is_binary(Signature);
valid_witness(_, _) -> false.

valid_identity({Ns, <<_:256>>}) when is_binary(Ns), byte_size(Ns) > 0 -> true;
valid_identity(_) -> false.

valid_principal({node, <<_:256>>}) -> true;
valid_principal(anonymous) -> true;
valid_principal(_) -> false.

-spec core(plan()) -> map().
core({quod_plan, Core, _Signer, _Signature}) -> Core.

-spec target(plan()) -> identity().
target(Plan) -> maps:get(target, core(Plan)).

-spec base_height(plan()) -> non_neg_integer().
base_height(Plan) -> maps:get(base_height, core(Plan)).

-spec proof_id(plan()) -> <<_:256>>.
proof_id(Plan) -> maps:get(proof_id, core(Plan)).

-spec origin(plan()) -> identity().
origin(Plan) -> maps:get(origin, core(Plan)).

-spec principal(plan()) -> principal().
principal(Plan) -> maps:get(principal, core(Plan)).

-spec overlay_generation(plan()) -> non_neg_integer().
overlay_generation(Plan) -> maps:get(overlay_generation, core(Plan)).

-spec signer(plan()) -> none | <<_:256>>.
signer({quod_plan, _Core, Signer, _Signature}) -> Signer.

-doc "Decode the plan's staged write-set. Owner-side only: allocates its atoms.".
-spec diff(plan()) -> [{assert | retract, {term(), term()}}].
diff(Plan) -> binary_to_term(maps:get(diff, core(Plan))).

-doc "Decode the plan's exact OCC read tokens. Owner-side only.".
-spec read_check(plan()) -> map().
read_check(Plan) -> binary_to_term(maps:get(read_check, core(Plan))).

-doc "Decode the plan's bounded invocation transcript. Owner-side only.".
-spec transcript(plan()) -> [transcript_entry()].
transcript(Plan) -> binary_to_term(maps:get(transcript, core(Plan))).
