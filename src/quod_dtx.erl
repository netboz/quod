-module(quod_dtx).
-moduledoc """
Shared durable proof plans, manifests, attestations and exact ledger references.

A local plan is the target-side record of everything one ontology scope
contributed to a distributed proof: its exact staged diff, its exact OCC read
tokens, the bounded invocation transcript, and the identities the plan binds —
sealed and witness-signed by the node that executed the scope. Co-hosted and
remote scopes seal through the same `seal_session/2`; only the transport of the
resulting plan differs.

## Envelope

The wire/memory form is one term:

    {quod_plan, Core, Signer, Signature}

`Core` is a map whose `diff`, `read_check`, `effects`, `live_bridges`, and
`transcript` values are
**nested deterministic ETF binaries of `quod_wire_term` values**, not raw
atom-bearing terms. A plan travels target →
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

A scope with an empty diff AND an empty read set seals to `not_material` unless
it is the signed request's origin plan or the explicit source role of an
unsigned multi-target atomic proof. The former carries request identity; the
latter provides the source vote even when all writes are foreign. A scope with a **material diff**
that consulted a live reality bridge (`m:quod_predicates` query-class external
predicates) cannot seal: its decisions rest on node-local, non-replayable
state that no later validation can re-prove, so sealing fails
`{non_transactional_dependency, Functor}`. `peer_ready/1` is admissible only
for the exact singleton membership diff that every validator re-proves before
voting; it remains a forbidden live dependency of ordinary content.

## Atomic protocol boundary

Plans, manifests, source/target attestations and exact ledger references are
shared by atomic and independent writes. The Vote/Resolve/Complete codec and
installed-role reducer live in `m:quod_atomic`; no old atomic phase decoder or
second reducer remains here. Plans retain only their own scope's material,
and the group carries a compact manifest, not another ontology's database.
""".

-include("quod_proof_limits.hrl").

%% Slot 1 is final by the ontology's pinned genesis block hash rather than by
%% a later consensus certificate.  Keeping that proof inside the existing
%% certified-reference shape lets fresh and long-lived ontologies use the one
%% exact-reference verifier.
-define(GENESIS_FINALITY_PROOF, <<"quod/genesis-anchor/v1">>).
-include("quod_client_goal_limits.hrl").
-include("quod_ledger.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-export([seal_session/2,
         verify/1,
         encode/1,
         decode/1,
         digest/1,
         core/1,
         target/1,
         base_height/1,
         proof_id/1,
         origin/1,
         principal/1,
         request_binding/1,
         overlay_generation/1,
         signer/1,
         valid_principal/1,
         participates/1,
         writes/1,
         reads_only/1,
         diff_ops/1,
         effects_count/1,
         diff_bytes/1,
         read_check_bytes/1,
         effects_bytes/1,
         material/1,
         new_manifest/1,
         manifest_digest/1,
         manifest_coordinator/1,
         manifest_participants/1,
         manifest_deadline/1,
         manifest_binding/1,
         attested_group_material/3,
         manifest_group_ref/2,
         encode_manifest/1,
         decode_manifest/1,
         attest_plan/5,
         verify_plan_attestation/4,
         attested_context/4,
         attestation_mode/1,
         encode_attestation/1,
         decode_attestation/1,
         certified_ref/6,
         certified_entry_ref/3,
         certified_entry_ref_matches/5,
         certified_ref_claim/1,
         same_certified_ref/2,
         validate_certified_ref/1,
         certified_ref_binding/1,
         event_context/2,
         conflict_descriptor/3]).
-export_type([plan/0, principal/0, transcript_entry/0,
              manifest/0, attestation/0, certified_ref/0]).

-define(PLAN_DOMAIN, <<"quod.dtx.plan">>).
-define(PLAN_VERSION, 8).

-define(MANIFEST_VERSION, 4).
-define(ATTESTATION_VERSION, 2).
-define(REF_VERSION, 2).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(MANIFEST_DOMAIN, <<"quod.dtx.manifest">>).
-define(ATTESTATION_DOMAIN, <<"quod.dtx.attestation">>).

-type identity() :: quod_proof_context:identity().
-type principal() :: {node, <<_:256>>} | {agent, binary()} | anonymous.
-type transcript_entry() ::
        {<<_:128>>, [identity()], binary(),
         allowed | denied, non_neg_integer(), binary(),
         active | complete | error | cancelled}.
-opaque plan() :: {quod_plan, map(), none | <<_:256>>, none | binary()}.

-type manifest() ::
        {quod_dtx_manifest, 4, <<_:256>>,
         {binary(), <<_:256>>, <<_:256>>, <<_:256>>}, <<_:256>>, principal(),
         binary(), <<_:256>>, binary(), <<_:256>>,
         quod_client_goal:request_binding(),
         [{identity(), <<_:256>>}], none | pos_integer()}.
-type attestation() ::
        {quod_dtx_attestation | quod_dtx_independent_attestation,
         2, identity(), <<_:256>>, <<_:256>>,
         <<_:256>>, <<_:512>>}.
-type certified_ref() ::
        {quod_dtx_ref, 2, binary(), <<_:256>>, pos_integer(),
         <<_:256>>, <<_:256>>, binary()}.
-doc """
Seal the calling worker's proof session into a signed local plan.

Must run in the session's owner process. `Bind` carries the identities the
plan is bound to: `target`, `base_height`, `proof_id`, `origin`, `principal`.
""".
-spec seal_session(quod_proof_session:session(),
                   #{target := identity(), base_height := non_neg_integer(),
                     proof_id := <<_:256>>, origin := identity(),
                     principal := principal(),
                     request_binding := quod_client_goal:request_binding(),
                     origin_role => boolean()}) ->
          {ok, plan()} | not_material | {error, term()}.
seal_session(Session,
             #{target := {_TargetNs, <<_:256>>} = Target,
               base_height := BaseHeight,
               proof_id := <<_:256>> = ProofId,
               origin := {_OriginNs, <<_:256>>} = Origin,
               principal := Principal,
               request_binding := RequestBinding} = Bind)
  when is_integer(BaseHeight), BaseHeight >= 0 ->
    true = valid_principal(Principal),
    true = quod_client_goal:valid_request_binding(RequestBinding),
    OriginRole = maps:get(origin_role, Bind, false),
    true = is_boolean(OriginRole) andalso
        (not OriginRole orelse Target =:= Origin),
    case quod_proof_session:check_access(Session) of
        ok ->
            seal_session_checked(
              Session, Target, BaseHeight, ProofId, Origin, Principal,
              RequestBinding, OriginRole);
        {error, _} = Error ->
            Error
    end.

seal_session_checked(Session, Target, BaseHeight, ProofId, Origin, Principal,
                     RequestBinding, OriginRole) ->
    Diff = quod_proof_session:local_changes(Session),
    ReadCheck = quod_proof_session:read_set(Session),
    Effects = quod_proof_session:effects(Session),
    Result =
        case {Diff, map_size(ReadCheck), Effects,
              OriginRole orelse operation_claim_plan(Target, Origin, RequestBinding)} of
            {[], 0, [], false} ->
                not_material;
            _ ->
                seal_material(
                  Session, Target, BaseHeight, ProofId, Origin, Principal,
                  RequestBinding,
                  Diff, ReadCheck, Effects)
        end,
    %% Extraction and encoding are pure, but the namespace may have committed
    %% Vote/Resolve while they ran. Never expose a plan (or even classify a
    %% scope as non-material) from a superseded proof generation.
    case quod_proof_session:check_access(Session) of
        ok -> Result;
        {error, _} = Error -> Error
    end.

seal_material(Session, Target, BaseHeight, ProofId, Origin, Principal,
              RequestBinding,
              Diff, ReadCheck, Effects) ->
    Bridges = quod_proof_session:live_bridges(Session),
    {Transcript, Generation} = quod_proof_session:transcript(Session),
    case seal_admissible(Diff, ReadCheck, Effects, Bridges) of
        ok ->
            case encode_material(
                   Diff, ReadCheck, Effects, Bridges, Transcript) of
                {ok, DiffBlob, ReadCheckBlob, EffectsBlob, BridgesBlob,
                 TranscriptBlob} ->
                    Core = #{target => Target,
                             base_height => BaseHeight,
                             proof_id => ProofId,
                             origin => Origin,
                             principal => Principal,
                             request_binding => RequestBinding,
                             overlay_generation => Generation,
                             %% Signed alongside the opaque diff so a consumer
                             %% that must not decode foreign vocabulary (the
                             %% proof origin) can still classify every OCC
                             %% participant.
                             diff_ops => length(Diff),
                             read_functors => map_size(ReadCheck),
                             effects_count => length(Effects),
                             conflict_descriptor =>
                                 conflict_descriptor(
                                   Diff, ReadCheck, Effects),
                             diff => DiffBlob,
                             read_check => ReadCheckBlob,
                             effects => EffectsBlob,
                             live_bridges => BridgesBlob,
                             transcript => TranscriptBlob},
                    sign_core(Core, quod_proof_session:signer(Session));
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

encode_material(Diff, ReadCheck, Effects, Bridges, Transcript) ->
    case {quod_wire_term:encode_canonical(Diff),
          quod_read_set:encode(ReadCheck),
          quod_wire_term:encode_canonical(Effects),
          quod_wire_term:encode_canonical(Bridges),
          quod_wire_term:encode_canonical(Transcript)} of
        {{ok, DiffBlob}, {ok, ReadCheckBlob}, {ok, EffectsBlob},
         {ok, BridgesBlob}, {ok, TranscriptBlob}}
          when byte_size(EffectsBlob) =< ?QUOD_MAX_DIRECT_EFFECT_BYTES,
               byte_size(TranscriptBlob) =< ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES ->
            {ok, DiffBlob, ReadCheckBlob, EffectsBlob, BridgesBlob,
             TranscriptBlob};
        {{ok, _}, {ok, _}, {ok, EffectsBlob}, {ok, _}, {ok, _}}
          when byte_size(EffectsBlob) > ?QUOD_MAX_DIRECT_EFFECT_BYTES ->
            {error, {too_large, effects}};
        {{ok, _}, {ok, _}, {ok, _}, {ok, _}, {ok, _TooLargeTranscript}} ->
            {error, {too_large, transcript}};
        _ ->
            {error, {too_large, plan}}
    end.

%% A material diff must not rest on live-bridge truth (module doc); the plan
%% itself must fit the network's fixed bounds before any signature is minted.
seal_admissible(Diff, ReadCheck, Effects, Bridges) ->
    EffectiveBridges = admissibility_bridges(Diff, Bridges),
    case {Diff, Effects, EffectiveBridges} of
        {[_ | _], _, [Functor | _]} ->
            {error, {non_transactional_dependency, Functor}};
        {[_ | _], [_ | _], _} ->
            {error, effect_requires_empty_diff};
        _ ->
            case {length(Diff) =< ?QUOD_MAX_PLAN_DIFF_OPS,
                  map_size(ReadCheck) =< ?QUOD_MAX_PLAN_READ_FUNCTORS,
                  quod_effect:validate_list(Effects)} of
                {true, true, true} -> ok;
                {false, _, _} -> {error, {too_large, plan}};
                {_, false, _} -> {error, {too_large, plan}};
                {_, _, false} -> {error, invalid_direct_effect}
            end
    end.

admissibility_bridges(Diff, Bridges) ->
    case quod_committee_predicates:membership_diff(Diff) of
        true -> lists:delete({peer_ready, 1}, Bridges);
        false -> Bridges
    end.

sign_core(Core, Signer) ->
    Bytes = plan_bytes(Core),
    Plan =
        case Signer of
            #{pubkey := Pubkey} = Identity ->
                {quod_plan, Core, Pubkey,
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
`effects`, `live_bridges`, and `transcript` binaries stay opaque until the
ontology that owns their symbols decodes them through `material/1`.
""".
-spec decode(binary()) -> {ok, plan()} | {error, term()}.
decode(Blob) when is_binary(Blob) ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_PLAN_ENVELOPE_BYTES) of
        {ok, {quod_plan, Core, Signer, Signature} = Plan} ->
            case deterministic(Plan) =:= Blob andalso valid_core(Core) andalso
                 valid_witness(Signer, Signature) of
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
             principal := Principal, request_binding := RequestBinding,
             overlay_generation := Generation,
             diff_ops := DiffOps, read_functors := ReadFunctors,
             effects_count := EffectsCount,
             conflict_descriptor := ConflictDescriptor,
             diff := Diff, read_check := ReadCheck, effects := Effects,
             live_bridges := Bridges,
             transcript := Transcript} = Core)
  when map_size(Core) =:= 16,
       is_integer(DiffOps), DiffOps >= 0,
       DiffOps =< ?QUOD_MAX_PLAN_DIFF_OPS,
       is_integer(ReadFunctors), ReadFunctors >= 0,
       ReadFunctors =< ?QUOD_MAX_PLAN_READ_FUNCTORS,
       is_integer(EffectsCount), EffectsCount >= 0,
       EffectsCount =< ?QUOD_MAX_DIRECT_EFFECTS ->
    valid_identity(Target) andalso valid_identity(Origin) andalso
        is_integer(BaseHeight) andalso BaseHeight >= 0 andalso
        is_binary(ProofId) andalso byte_size(ProofId) =:= 32 andalso
        valid_principal(Principal) andalso
        quod_client_goal:valid_request_binding(RequestBinding) andalso
        valid_conflict_descriptor(ConflictDescriptor) andalso
        is_integer(Generation) andalso Generation >= 0 andalso
        Generation =< ?MAX_UINT64 andalso
        is_binary(Diff) andalso
        byte_size(Diff) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES andalso
        is_binary(ReadCheck) andalso
        byte_size(ReadCheck) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES andalso
        is_binary(Effects) andalso
        byte_size(Effects) =< ?QUOD_MAX_DIRECT_EFFECT_BYTES andalso
        is_binary(Bridges) andalso
        byte_size(Bridges) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES andalso
        is_binary(Transcript) andalso
        byte_size(Transcript) =< ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES;
valid_core(_) ->
    false.

valid_witness(none, none) -> true;
valid_witness(<<_:256>>, <<_:512>>) -> true;
valid_witness(_, _) -> false.

valid_identity({Ns, <<_:256>>}) when is_binary(Ns), byte_size(Ns) > 0 -> true;
valid_identity(_) -> false.

-doc "Validate the one principal alphabet shared by plans and scopes.".
-spec valid_principal(term()) -> boolean().
valid_principal({node, <<_:256>>}) -> true;
valid_principal(Principal = {agent, _}) ->
    quod_agent_ref:valid_principal(Principal);
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

-spec request_binding(plan()) -> quod_client_goal:request_binding().
request_binding(Plan) -> maps:get(request_binding, core(Plan)).

-spec overlay_generation(plan()) -> non_neg_integer().
overlay_generation(Plan) -> maps:get(overlay_generation, core(Plan)).

-spec signer(plan()) -> none | <<_:256>>.
signer({quod_plan, _Core, Signer, _Signature}) -> Signer.

-doc "SHA-256 of the plan's canonical unsigned bytes — what an envelope binds.".
-spec digest(plan()) -> <<_:256>>.
digest(Plan) -> crypto:hash(sha256, plan_bytes(core(Plan))).

-doc "The signed count of staged write operations; safe on a foreign plan.".
-spec diff_ops(plan()) -> non_neg_integer().
diff_ops(Plan) -> maps:get(diff_ops, core(Plan)).

-doc "Whether a plan writes, contributes OCC reads, or carries the origin claim.".
-spec participates(plan()) -> boolean().
participates(Plan) ->
    writes(Plan) orelse reads_only(Plan) orelse
        operation_claim_plan(
          target(Plan), origin(Plan), request_binding(Plan)).

-doc "Whether this ontology must commit a write or direct effect.".
-spec writes(plan()) -> boolean().
writes(Plan) ->
    diff_ops(Plan) > 0 orelse effects_count(Plan) > 0.

-doc "Whether this plan contributes OCC reads but no write or direct effect.".
-spec reads_only(plan()) -> boolean().
reads_only(Plan) ->
    not writes(Plan) andalso maps:get(read_functors, core(Plan)) > 0.

operation_claim_plan(
  Identity, Identity, {agent_goal_v1, <<_:256>>}) -> true;
operation_claim_plan(_Target, _Origin, _RequestBinding) -> false.

-doc "The signed count of staged direct effects; safe on a foreign plan.".
-spec effects_count(plan()) -> non_neg_integer().
effects_count(Plan) -> maps:get(effects_count, core(Plan)).

-doc "The plan's canonical opaque write-set bytes; safe on a foreign plan.".
-spec diff_bytes(plan()) -> binary().
diff_bytes(Plan) -> maps:get(diff, core(Plan)).

-doc "The plan's canonical opaque OCC read-set bytes; safe on a foreign plan.".
-spec read_check_bytes(plan()) -> binary().
read_check_bytes(Plan) -> maps:get(read_check, core(Plan)).

-doc "The plan's canonical opaque direct-effect bytes.".
-spec effects_bytes(plan()) -> binary().
effects_bytes(Plan) -> maps:get(effects, core(Plan)).

-doc """
Decode, jointly materialize, and validate target-owned plan payloads once.

This is the atom-allocation boundary. The owning ontology must first verify the
outer signature and exact target binding; foreign holders keep these blobs
opaque and use only the signed counts and digests.
""".
-spec material(plan()) ->
          {ok, #{diff := list(), read_check := map(),
                 effects := [quod_effect:effect()],
                 live_bridges := [{atom(), arity()}],
                 transcript := [transcript_entry()]}} |
          {error, {protocol_error, bad_payload} |
                  too_many_new_atoms | atom_limit}.
material(Plan) ->
    Core = core(Plan),
    case decode_material(Core) of
        {ok, Decoded} -> materialize_decoded(Core, Decoded);
        error ->
            {error, {protocol_error, bad_payload}}
    end.

decode_material(Core) ->
    case {decode_material_blob(maps:get(diff, Core)),
          decode_material_blob(maps:get(read_check, Core)),
          decode_material_blob(maps:get(effects, Core)),
          decode_material_blob(maps:get(live_bridges, Core)),
          decode_material_blob(maps:get(transcript, Core))} of
        {{ok, Diff}, {ok, ReadPairs}, {ok, Effects}, {ok, Bridges},
         {ok, Transcript}}
          when is_list(Diff), is_list(ReadPairs), is_list(Effects),
               is_list(Bridges), is_list(Transcript) ->
            %% Validate the carried order and aliases before vocabulary can
            %% materialize. The eventual map is only a lookup index.
            case {quod_read_set:valid_pairs(ReadPairs),
                  exact_length(ReadPairs, maps:get(read_functors, Core), 0),
                  attach_transcript_goals(Transcript, 0, [])} of
                {true, true, {ok, AnnotatedTranscript}} ->
                    {ok, {Diff, ReadPairs, Effects, Bridges,
                          AnnotatedTranscript}};
                _ ->
                    error
            end;
        _ ->
            error
    end.

decode_material_blob(Blob) ->
    quod_wire_term:decode_canonical(Blob, ?QUOD_MAX_PLAN_ENVELOPE_BYTES).

attach_transcript_goals([], _Count, Acc) ->
    {ok, lists:reverse(Acc)};
attach_transcript_goals(
  [{InvocationId, Chain, GoalBlob, Verdict, AnswerCount, Digest, Tag} | Rest],
  Count, Acc)
  when Count < ?QUOD_MAX_INVOCATIONS_PER_SCOPE,
       is_binary(GoalBlob),
       byte_size(GoalBlob) =< ?QUOD_MAX_NESTED_GOAL_BYTES ->
    case quod_wire_term:decode_canonical(
           GoalBlob, ?QUOD_MAX_NESTED_GOAL_BYTES) of
        {ok, Goal} ->
            Annotated =
                {InvocationId, Chain, GoalBlob, Goal, Verdict,
                 AnswerCount, Digest, Tag},
            attach_transcript_goals(Rest, Count + 1, [Annotated | Acc]);
        {error, _} ->
            error
    end;
attach_transcript_goals(_MalformedOrTooLong, _Count, _Acc) ->
    error.

materialize_decoded(Core, Decoded) ->
    case quod_wire_term:materialize_symbols(Decoded) of
        {ok, {Diff, ReadPairs, Effects, Bridges, AnnotatedTranscript}} ->
            %% decode_material/1 already validated the ordered pair list.
            ReadCheck = maps:from_list(ReadPairs),
            case strip_transcript_goals(AnnotatedTranscript, []) of
                {ok, Transcript} ->
                    case exact_length(Diff, maps:get(diff_ops, Core), 0)
                         andalso exact_length(
                                   Effects, maps:get(effects_count, Core), 0)
                         andalso quod_diff:valid_ops(Diff)
                         andalso quod_effect:validate_list(Effects)
                         andalso valid_live_bridges(Bridges)
                         andalso seal_admissible(
                                   Diff, ReadCheck, Effects, Bridges) =:= ok
                         andalso valid_transcript(Transcript, 0)
                         andalso conflict_descriptor(
                                   Diff, ReadCheck, Effects) =:=
                                     maps:get(conflict_descriptor, Core) of
                        true ->
                            {ok, #{diff => Diff, read_check => ReadCheck,
                                   effects => Effects,
                                   live_bridges => lists:sort(Bridges),
                                   transcript => Transcript}};
                        false ->
                            {error, {protocol_error, bad_payload}}
                    end;
                _ ->
                    {error, {protocol_error, bad_payload}}
            end;
        {error, malformed_material} ->
            {error, {protocol_error, bad_payload}};
        {error, Reason} ->
            {error, Reason}
    end.

%% Signed atom-safe conflict keys shared by plan sealing and atomic admission.

conflict_descriptor(Diff, ReadCheck, Effects) ->
    Reads = lists:sort([conflict_functor(Key) || Key <- maps:keys(ReadCheck)]),
    Writes = lists:usort(
               [conflict_functor(erlog_int:functor(Head))
                || {Operation, {Head, _Body}} <- Diff,
                   Operation =:= assert orelse Operation =:= retract]),
    Custody = lists:usort([quod_effect:target(Effect) || Effect <- Effects]),
    #{reads => Reads, writes => Writes, custody => Custody}.

conflict_functor({Name, Arity}) -> {atom_to_binary(Name, utf8), Arity}.

valid_conflict_descriptor(
  #{reads := Reads, writes := Writes, custody := Custody} = Descriptor)
  when map_size(Descriptor) =:= 3 ->
    valid_conflict_functors(Reads, none) andalso
        valid_conflict_functors(Writes, none) andalso
        valid_conflict_identities(Custody, none);
valid_conflict_descriptor(_) -> false.

valid_conflict_functors([], _Previous) -> true;
valid_conflict_functors([{Name, Arity} = Key | Rest], Previous)
  when is_binary(Name), byte_size(Name) > 0,
       is_integer(Arity), Arity >= 0,
       (Previous =:= none orelse Previous < Key) ->
    valid_conflict_functors(Rest, Key);
valid_conflict_functors(_, _) -> false.

valid_conflict_identities([], _Previous) -> true;
valid_conflict_identities([Identity | Rest], Previous)
  when Previous =:= none; Previous < Identity ->
    valid_identity(Identity) andalso
        valid_conflict_identities(Rest, Identity);
valid_conflict_identities(_, _) -> false.

strip_transcript_goals([], Acc) ->
    {ok, lists:reverse(Acc)};
strip_transcript_goals(
  [{InvocationId, Chain, GoalBlob, Goal, Verdict,
    AnswerCount, Digest, Tag} | Rest], Acc) ->
    case quod_wire_term:encode_canonical(Goal) of
        {ok, GoalBlob} ->
            Entry = {InvocationId, Chain, GoalBlob, Verdict,
                     AnswerCount, Digest, Tag},
            strip_transcript_goals(Rest, [Entry | Acc]);
        _ ->
            error
    end;
strip_transcript_goals(_Malformed, _Acc) ->
    error.

exact_length([], Expected, Expected) ->
    true;
exact_length([_ | Rest], Expected, Count) when Count < Expected ->
    exact_length(Rest, Expected, Count + 1);
exact_length(_MalformedOrWrongCount, _Expected, _Count) ->
    false.

valid_live_bridges(Bridges) ->
    Bridges =:= lists:usort(Bridges) andalso
        lists:all(
          fun({Name, Arity}) ->
                  is_atom(Name) andalso is_integer(Arity) andalso Arity >= 0;
             (_) -> false
          end,
          Bridges).

valid_transcript([], Count) ->
    Count =< ?QUOD_MAX_INVOCATIONS_PER_SCOPE;
valid_transcript([Entry | Rest], Count)
  when Count < ?QUOD_MAX_INVOCATIONS_PER_SCOPE ->
    valid_transcript_entry(Entry) andalso
        valid_transcript(Rest, Count + 1);
valid_transcript(_ImproperOrTooLong, _Count) ->
    false.

valid_transcript_entry(
  {<<_:128>>, Chain, GoalBin, Verdict, AnswerCount, <<_:256>>, Tag}) ->
    valid_chain(Chain, 0) andalso
        is_binary(GoalBin) andalso
        byte_size(GoalBin) =< ?QUOD_MAX_NESTED_GOAL_BYTES andalso
        (Verdict =:= allowed orelse Verdict =:= denied) andalso
        is_integer(AnswerCount) andalso AnswerCount >= 0 andalso
        AnswerCount =< ?QUOD_MAX_ANSWERS_PER_INVOCATION andalso
        (Tag =:= active orelse Tag =:= complete orelse
         Tag =:= error orelse Tag =:= cancelled);
valid_transcript_entry(_) ->
    false.

valid_chain([], _Depth) ->
    true;
valid_chain([Identity | Rest], Depth)
  when Depth < ?QUOD_MAX_ACTIVE_PROOF_DEPTH ->
    valid_identity(Identity) andalso valid_chain(Rest, Depth + 1);
valid_chain(_ImproperOrTooDeep, _Depth) ->
    false.

%% ===================================================================
%% Shared manifests, attestations and exact references
%% ===================================================================

-doc "Build the shared manifest; atomic groups bind a vote deadline, independent claims use none.".
-spec new_manifest(map()) -> {ok, manifest()} | {error, term()}.
new_manifest(#{proof_id := <<_:256>> = ProofId,
               coordinator := Coordinator,
               nonce := <<_:256>> = Nonce,
               principal := Principal,
               request_binding := RequestBinding,
               goal := Goal,
               result := Result,
               participants := Participants,
               vote_deadline_ms := VoteDeadline} = Input)
  when map_size(Input) =:= 9, is_binary(Goal), is_binary(Result) ->
    case {byte_size(Goal) =< ?QUOD_MAX_TOPLEVEL_GOAL_BYTES,
          byte_size(Result) =< ?QUOD_MAX_DURABLE_RESULT_BYTES,
          bounded_length(Participants, ?QUOD_MAX_DTX_PARTICIPANTS)} of
        {true, true, {ok, _}} ->
            case canonical_identity_digest_rows(Participants) of
                {ok, CanonicalParticipants} ->
                    Manifest =
                        {quod_dtx_manifest, ?MANIFEST_VERSION, ProofId,
                         Coordinator, Nonce, Principal, Goal,
                         crypto:hash(sha256, Goal), Result,
                         crypto:hash(sha256, Result), RequestBinding,
                         CanonicalParticipants, VoteDeadline},
                    case within_body_limit(Manifest) andalso
                         valid_manifest(Manifest) of
                        true -> {ok, Manifest};
                        false -> manifest_error(Manifest)
                    end;
                error ->
                    {error, invalid_manifest}
            end;
        {false, _, _} ->
            {error, {too_large, goal}};
        {_, false, _} ->
            {error, {too_large, result}};
        _ ->
            {error, invalid_manifest}
    end;
new_manifest(_) ->
    {error, invalid_manifest}.

manifest_error(Manifest) ->
    case not within_body_limit(Manifest) of
        true -> {error, {too_large, dtx_body}};
        false -> {error, invalid_manifest}
    end.

-doc "Domain-separated digest signed by every manifest target.".
-spec manifest_digest(manifest()) -> <<_:256>>.
manifest_digest(Manifest) ->
    true = valid_manifest(Manifest),
    manifest_digest_unchecked(Manifest).

manifest_digest_unchecked(Manifest) ->
    crypto:hash(
      sha256,
      deterministic({?MANIFEST_DOMAIN, ?MANIFEST_VERSION, Manifest})).

-doc "Encode one validated manifest for the scope-attestation wire.".
-spec encode_manifest(manifest()) ->
          {ok, binary()} | {error, {too_large, manifest} | invalid_manifest}.
encode_manifest(Manifest) ->
    case valid_manifest(Manifest) of
        true ->
            Encoded = deterministic(Manifest),
            case byte_size(Encoded) =< ?QUOD_MAX_DTX_BODY_BYTES of
                true -> {ok, Encoded};
                false -> {error, {too_large, manifest}}
            end;
        false ->
            {error, invalid_manifest}
    end.

-doc "Decode one canonical, bounded manifest without allocating ontology atoms.".
-spec decode_manifest(binary()) -> {ok, manifest()} | {error, term()}.
decode_manifest(Blob) when is_binary(Blob) ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, Manifest} ->
            case deterministic(Manifest) =:= Blob andalso
                 valid_manifest(Manifest) of
                true -> {ok, Manifest};
                false -> {error, {protocol_error, bad_payload}}
            end;
        {error, too_large} ->
            {error, {too_large, manifest}};
        {error, _} ->
            {error, {protocol_error, bad_payload}}
    end;
decode_manifest(_) ->
    {error, {protocol_error, bad_payload}}.

-doc """
Sign this target's unchanged local plan into one manifest.

The scope owner supplies its own sealed material provenance, never a value
from the origin. Exactly mask 2 grants independent eligibility. This is a
permission on this target's material, not selection of the operation's lane:
ordinary fallback may still use an independently eligible plan atomically.
Both arms remain useful protocol statements; the ordinary arm retains its
exact signature bytes for L3 and ordinary single-target claims. Multi-target
independent claims require each target's independent attestation.
""".
-spec attest_plan(0..3, identity(), plan(), manifest(), quod_identity:signer()) ->
          {ok, attestation()} | {error, term()}.
attest_plan(Provenance, Target, Plan, Manifest,
            #{pubkey := <<_:256>> = Pubkey} = Identity)
  when is_integer(Provenance), Provenance >= 0, Provenance =< 3 ->
    case valid_manifest(Manifest) andalso valid_identity(Target) andalso
         valid_signed_plan(Plan) andalso effect_plan_valid(Plan) of
        true ->
            ManifestDigest = manifest_digest_unchecked(Manifest),
            PlanDigest = digest(Plan),
            case plan_matches_manifest(
                   Target, Plan, PlanDigest, Manifest) andalso
                signer(Plan) =:= Pubkey of
                true ->
                    Tag = case Provenance of
                              2 -> quod_dtx_independent_attestation;
                              _ -> quod_dtx_attestation
                          end,
                    Bytes = attestation_bytes(
                              Tag, Target, PlanDigest, ManifestDigest),
                    {ok,
                     {Tag, ?ATTESTATION_VERSION, Target,
                      PlanDigest, ManifestDigest, Pubkey,
                      quod_identity:sign(Bytes, Identity)}};
                false ->
                    {error, invalid_plan_attestation}
            end;
        false ->
            {error, invalid_plan_attestation}
    end;
attest_plan(_, _, _, _, _) ->
    {error, invalid_plan_attestation}.

-doc "Inspect target eligibility only after verifying the exact attestation.".
-spec attestation_mode(attestation()) -> ordinary | independent | invalid.
attestation_mode(Attestation) ->
    case valid_attestation(Attestation) of
        true ->
            case element(1, Attestation) of
                quod_dtx_attestation -> ordinary;
                quod_dtx_independent_attestation -> independent
            end;
        false -> invalid
    end.

-doc "Verify the exact target/plan/manifest binding of one attestation.".
-spec verify_plan_attestation(identity(), plan(), manifest(), attestation()) ->
          boolean().
verify_plan_attestation(
  Target, Plan, Manifest, Attestation) ->
    valid_manifest(Manifest) andalso
        valid_identity(Target) andalso valid_signed_plan(Plan) andalso
        verify_plan_attestation_preverified(
          Target, Plan, Manifest, manifest_digest_unchecked(Manifest),
          Attestation).

-doc "Authenticate one target's attested plan and return its bound event context.".
-spec attested_context(identity(), plan(), manifest(), attestation()) ->
          {ok, map()} | error.
attested_context(Target, Plan, Manifest, Attestation) ->
    %% Verification is the same boundary used by boolean consumers. Carry its
    %% authenticated projection forward instead of verifying again to read it.
    case verify_plan_attestation(Target, Plan, Manifest, Attestation) of
        true -> {ok, manifest_plan_context(Manifest, digest(Plan))};
        false -> error
    end.

verify_plan_attestation_preverified(
  Target, Plan, Manifest, ManifestDigest,
  {Tag, ?ATTESTATION_VERSION, Target,
   <<_:256>> = PlanDigest, ManifestDigest, <<_:256>> = Attestor,
   <<_:512>> = Signature})
  when Tag =:= quod_dtx_attestation;
       Tag =:= quod_dtx_independent_attestation ->
    attestation_matches_plan(Target, Plan, PlanDigest, Attestor, Manifest) andalso
        quod_identity:verify(
          Signature,
          attestation_bytes(Tag, Target, PlanDigest, ManifestDigest),
          Attestor);
verify_plan_attestation_preverified(_, _, _, _, _) -> false.

attestation_matches_plan(Target, Plan, PlanDigest, Attestor, Manifest) ->
    digest(Plan) =:= PlanDigest andalso
        plan_matches_manifest(Target, Plan, PlanDigest, Manifest) andalso
        signer(Plan) =:= Attestor.

-doc "Encode the fixed-shape target attestation returned by a sealed scope.".
-spec encode_attestation(attestation()) ->
          {ok, binary()} | {error, invalid_plan_attestation}.
encode_attestation(Attestation) ->
    case valid_attestation(Attestation) of
        true -> {ok, deterministic(Attestation)};
        false -> {error, invalid_plan_attestation}
    end.

-doc "Decode one canonical target attestation; verify its plan binding separately.".
-spec decode_attestation(binary()) -> {ok, attestation()} | {error, term()}.
decode_attestation(Blob) when is_binary(Blob) ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, Attestation} ->
            case deterministic(Attestation) =:= Blob andalso
                 valid_attestation(Attestation) of
                true -> {ok, Attestation};
                false -> {error, {protocol_error, bad_payload}}
            end;
        {error, too_large} ->
            {error, {too_large, attestation}};
        {error, _} ->
            {error, {protocol_error, bad_payload}}
    end;
decode_attestation(_) ->
    {error, {protocol_error, bad_payload}}.

valid_attestation(
  {Tag, ?ATTESTATION_VERSION, Target,
   <<_:256>>, <<_:256>>, <<_:256>>, <<_:512>>})
  when Tag =:= quod_dtx_attestation;
       Tag =:= quod_dtx_independent_attestation ->
    valid_identity(Target);
valid_attestation(_) ->
    false.

plan_matches_manifest(Target, Plan, PlanDigest, Manifest) ->
    {OriginNs, OriginAnchor, _Coordinator, _Admission} =
        manifest_coordinator(Manifest),
    target(Plan) =:= Target andalso
        proof_id(Plan) =:= manifest_proof_id(Manifest) andalso
        origin(Plan) =:= {OriginNs, OriginAnchor} andalso
        principal(Plan) =:= manifest_principal(Manifest) andalso
        request_binding(Plan) =:= manifest_request_binding(Manifest) andalso
        lists:keyfind(Target, 1, manifest_participants(Manifest)) =:=
            {Target, PlanDigest}.

effect_plan_valid(Plan) ->
    case material(Plan) of
        {ok, Material} -> quod_effect:validate_plan(Plan, Material);
        {error, _} -> false
    end.

valid_signed_plan({quod_plan, Core, <<_:256>>, <<_:512>>} = Plan) ->
    valid_core(Core) andalso verify(Plan);
valid_signed_plan(_) -> false.

attestation_bytes(quod_dtx_attestation, Target, PlanDigest, ManifestDigest) ->
    deterministic(
      {?ATTESTATION_DOMAIN, ?ATTESTATION_VERSION,
       {Target, PlanDigest, ManifestDigest}});
attestation_bytes(quod_dtx_independent_attestation, Target, PlanDigest, ManifestDigest) ->
    deterministic(
      {<<"quod.dtx.independent_attestation">>, ?ATTESTATION_VERSION,
       {Target, PlanDigest, ManifestDigest}}).

-doc "Construct the fixed certified-ledger-reference value.".
-spec certified_ref(binary(), <<_:256>>, pos_integer(), <<_:256>>,
                    <<_:256>>, binary()) ->
          {ok, certified_ref()} | {error, invalid_certified_ref}.
certified_ref(Ns, <<_:256>> = Anchor, Slot, <<_:256>> = BlockHash,
              <<_:256>> = RecordDigest, FinalityProof)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_binary(FinalityProof), byte_size(FinalityProof) > 0,
       byte_size(FinalityProof) =< ?QUOD_MAX_DTX_BODY_BYTES ->
    {ok,
     {quod_dtx_ref, ?REF_VERSION, Ns, Anchor, Slot, BlockHash,
      RecordDigest, FinalityProof}};
certified_ref(_, _, _, _, _, _) ->
    {error, invalid_certified_ref}.

-doc """
Build the certified reference for one exact committed DTX control or content
transaction.

The entry must carry a commit certificate for its own slot and reconstructed
block hash. The reference embeds the canonical certificate bytes as finality
evidence and binds the semantic control digest. This is the single pure seam
used by consensus history and ordered Prolog apply; neither consumer rebuilds
or encodes the certificate independently.
""".
-spec certified_entry_ref({binary(), <<_:256>>}, quod_ledger:entry_artifact(),
                          quod_atomic:control() | #transaction{}) ->
          {ok, certified_ref()} | {error, invalid_certified_entry}.
certified_entry_ref(Identity, Entry, Record) ->
    View = try quod_ledger:entry_view(Entry)
           catch error:_ -> invalid
           end,
    certified_entry_ref_view(Identity, Entry, View, Record).

certified_entry_ref_view(
  {Ns, <<_:256>> = Anchor},
  Entry, #entry{index = 1, data = {batch, [Transaction]}, cert = none},
  #transaction{tx_id = TxId, sig = none,
               origin = {Ns, <<0:256>>}, proof_id = none,
               plan_digest = none} = Transaction)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(TxId), byte_size(TxId) > 0 ->
    case quod_simplex:block_from_entry(Entry) of
        {ok, Block} ->
            case quod_simplex:block_hash(Block) =:= Anchor of
                true ->
                    case certified_ref(
                           Ns, Anchor, 1, Anchor,
                           crypto:hash(sha256, TxId),
                           ?GENESIS_FINALITY_PROOF) of
                        {ok, Ref} -> {ok, Ref};
                        {error, _} -> {error, invalid_certified_entry}
                    end;
                false ->
                    {error, invalid_certified_entry}
            end;
        error ->
            {error, invalid_certified_entry}
    end;
certified_entry_ref_view(
  {Ns, <<_:256>> = Anchor},
  Entry, #entry{index = Slot, data = {batch, Transactions},
         cert = #cert{kind = commit, slot = Slot,
                      block_hash = BlockHash} = Cert},
  #transaction{tx_id = <<_:256>> = TxId} = Transaction)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(BlockHash), byte_size(BlockHash) =:= 32,
       is_list(Transactions) ->
    case {quod_simplex:block_from_entry(Entry),
          [T || #transaction{tx_id = CandidateId} = T <- Transactions,
                CandidateId =:= TxId]} of
        {{ok, Block}, [Transaction]} ->
            case quod_simplex:block_hash(Block) =:= BlockHash of
                true ->
                    case certified_ref(
                           Ns, Anchor, Slot, BlockHash, TxId,
                           term_to_binary(Cert, [deterministic])) of
                        {ok, Ref} -> {ok, Ref};
                        {error, _} -> {error, invalid_certified_entry}
                    end;
                false ->
                    {error, invalid_certified_entry}
            end;
        _ ->
            {error, invalid_certified_entry}
    end;
certified_entry_ref_view(
  {Ns, <<_:256>> = Anchor},
  Entry, #entry{index = Slot, data = {batch, Items},
         cert = #cert{kind = commit, slot = Slot,
                      block_hash = BlockHash} = Cert},
  Control)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(BlockHash), byte_size(BlockHash) =:= 32 ->
    case quod_simplex:block_from_entry(Entry) of
        {ok, Block} ->
            %% The artifact already authenticated/classified the batch. Select
            %% its exact member without re-running the whole wave's checks.
            case quod_simplex:block_hash(Block) =:= BlockHash andalso
                 [C || {dtx, C} <- Items, C =:= Control,
                       quod_atomic:control_target(C) =:= {Ns, Anchor}] of
                [Owned] ->
                    case certified_ref(
                           Ns, Anchor, Slot, BlockHash,
                           quod_atomic:record_digest(Owned),
                           term_to_binary(Cert, [deterministic])) of
                        {ok, Ref} -> {ok, Ref};
                        {error, _} -> {error, invalid_certified_entry}
                    end;
                _ ->
                    {error, invalid_certified_entry}
            end;
        _ ->
            {error, invalid_certified_entry}
    end;
certified_entry_ref_view(_, _, _, _) ->
    {error, invalid_certified_entry}.

-doc """
Verify that one certified reference names this exact committed record.

Commit certificates are quorum proofs, not canonical byte strings: two honest
replicas may retain different valid quorum subsets for the same block.  The
reference therefore binds the immutable block and record fields exactly, then
verifies its own supplied finality proof against the committee for that slot;
it never requires that proof to equal the certificate bytes retained locally.
""".
-spec certified_entry_ref_matches(
        identity(), quod_ledger:entry_artifact(), quod_atomic:control() | #transaction{},
        certified_ref(), [<<_:256>>]) -> boolean().
certified_entry_ref_matches(
  Identity = {Ns, <<_:256>> = Anchor}, Entry, Record, Ref, Committee)
  when is_binary(Ns), byte_size(Ns) > 0, is_list(Committee) ->
    case certified_entry_ref(Identity, Entry, Record) of
        {ok, ExpectedRef} ->
            case {certified_ref_claim(ExpectedRef),
                  certified_ref_claim(Ref)} of
                {Core, Core} ->
                    valid_certified_ref_finality(
                      Ns, Anchor, Ref, Committee);
                _ ->
                    false
            end;
        {error, _} ->
            false
    end;
certified_entry_ref_matches(_Identity, _Entry, _Record, _Ref, _Committee) ->
    false.

-doc "Return the immutable claim without treating its finality-proof bytes as identity.".
-spec certified_ref_claim(certified_ref()) ->
          {ok, {identity(), pos_integer(), <<_:256>>, <<_:256>>}} | error.
certified_ref_claim(
  {quod_dtx_ref, ?REF_VERSION, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>> = BlockHash, <<_:256>> = RecordDigest, _FinalityProof} = Ref)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    case validate_certified_ref(Ref) of
        true -> {ok, {{Ns, Anchor}, Slot, BlockHash, RecordDigest}};
        false -> error
    end;
certified_ref_claim(_Malformed) ->
    error.

-doc "Compare the immutable claim of two certified references, excluding their interchangeable finality-proof subsets.".
-spec same_certified_ref(certified_ref(), certified_ref()) -> boolean().
same_certified_ref(Left, Right) ->
    case {certified_ref_claim(Left), certified_ref_claim(Right)} of
        {{ok, Claim}, {ok, Claim}} -> true;
        _ -> false
    end.

valid_certified_ref_finality(
  _Ns, _Anchor,
  {quod_dtx_ref, ?REF_VERSION, _RefNs, _RefAnchor, 1,
   _BlockHash, _RecordDigest, ?GENESIS_FINALITY_PROOF}, _Committee) ->
    true;
valid_certified_ref_finality(
  Ns, Anchor,
  {quod_dtx_ref, ?REF_VERSION, Ns, Anchor, Slot, BlockHash,
   _RecordDigest, FinalityProof}, Committee)
  when is_integer(Slot), Slot > 1, is_binary(FinalityProof) ->
    try binary_to_term(FinalityProof, [safe]) of
        #cert{kind = commit, slot = Slot, block_hash = BlockHash} = Cert ->
            quod_simplex:verify_cert(
              quod_simplex:consensus_domain(Ns, Anchor), Cert, Committee);
        _ ->
            false
    catch _:_ ->
        false
    end;
valid_certified_ref_finality(
  _Ns, _Anchor, _Malformed, _Committee) ->
    false.

-doc "Shape-check a certified reference without interpreting its proof.".
-spec validate_certified_ref(term()) -> boolean().
validate_certified_ref(
  {quod_dtx_ref, ?REF_VERSION, Ns, <<_:256>>, Slot, <<_:256>>, <<_:256>>,
   FinalityProof})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_binary(FinalityProof), byte_size(FinalityProof) > 0,
       byte_size(FinalityProof) =< ?QUOD_MAX_DTX_BODY_BYTES ->
    true;
validate_certified_ref(_) ->
    false.

-doc "Return the exact target, slot, and semantic digest bound by a valid ref.".
-spec certified_ref_binding(certified_ref()) ->
          {ok, identity(), pos_integer(), <<_:256>>} | error.
certified_ref_binding(
  {quod_dtx_ref, ?REF_VERSION, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>>, <<_:256>> = RecordDigest, _FinalityProof} = Ref) ->
    case validate_certified_ref(Ref) of
        true -> {ok, {Ns, Anchor}, Slot, RecordDigest};
        false -> error
    end;
certified_ref_binding(_) ->
    error.

-doc "Canonical runtime-event context shared by one manifest-bound plan.".
-spec event_context(manifest(), plan()) -> {ok, map()} | error.
event_context(Manifest, Plan) ->
    case valid_manifest(Manifest) andalso valid_signed_plan(Plan) of
        true ->
            PlanDigest = digest(Plan),
            Target = target(Plan),
            case plan_matches_manifest(
                   Target, Plan, PlanDigest, Manifest) of
                true ->
                    {ok, manifest_plan_context(Manifest, PlanDigest)};
                false ->
                    error
            end;
        false ->
            error
    end.

-spec manifest_plan_context(manifest(), <<_:256>>) -> map().
manifest_plan_context(Manifest, PlanDigest) ->
    {OriginNs, OriginAnchor, _, _} = manifest_coordinator(Manifest),
    {quod_dtx_manifest, ?MANIFEST_VERSION, ProofId, _, _, Principal,
     Goal, _, Result, _, _RequestBinding, _, _VoteDeadline} = Manifest,
    #{proof_id => ProofId, origin => {OriginNs, OriginAnchor},
      principal => Principal, goal => Goal, result => Result,
      plan_digest => PlanDigest}.

valid_manifest(
  {quod_dtx_manifest, ?MANIFEST_VERSION, <<_:256>>,
   {OriginNs, <<_:256>>, <<_:256>>, <<_:256>>}, <<_:256>>, Principal,
   Goal, <<_:256>> = GoalDigest, Result, <<_:256>> = ResultDigest,
   RequestBinding, Participants, VoteDeadline})
  when is_binary(OriginNs), byte_size(OriginNs) > 0,
       is_binary(Goal), byte_size(Goal) =< ?QUOD_MAX_TOPLEVEL_GOAL_BYTES,
       is_binary(Result), byte_size(Result) =< ?QUOD_MAX_DURABLE_RESULT_BYTES ->
    (VoteDeadline =:= none orelse
        (is_integer(VoteDeadline) andalso VoteDeadline > 0 andalso VoteDeadline =< ?MAX_UINT64))
        andalso valid_principal(Principal) andalso
        quod_client_goal:valid_request_binding(RequestBinding) andalso
        valid_participants(Participants) andalso
        crypto:hash(sha256, Goal) =:= GoalDigest andalso
        crypto:hash(sha256, Result) =:= ResultDigest andalso
        durable_blobs_valid(Goal, Result);
valid_manifest(_) ->
    false.

durable_blobs_valid(Goal, Result) ->
    case {quod_durable_term:decode_goal(Goal),
          quod_durable_term:decode_result(Result)} of
        {{ok, _}, {ok, _}} -> true;
        _ -> false
    end.

valid_participants(Participants) ->
    case bounded_length(Participants, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, Length} when Length >= 1 ->
            valid_identity_digest_rows(Participants, none);
        _ ->
            false
    end.

valid_identity_digest_rows([], _Previous) -> true;
valid_identity_digest_rows([{Identity, <<_:256>>} | Rest], Previous)
  when Previous =:= none; Previous < Identity ->
    valid_identity(Identity) andalso
        valid_identity_digest_rows(Rest, Identity);
valid_identity_digest_rows(_, _) -> false.

canonical_identity_digest_rows(Rows) ->
    case bounded_length(Rows, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, Length} when Length >= 1 ->
            case lists:all(
                   fun({Identity, <<_:256>>}) -> valid_identity(Identity);
                      (_) -> false
                   end, Rows) of
                true ->
                    Sorted = lists:keysort(1, Rows),
                    case valid_identity_digest_rows(Sorted, none) of
                        true -> {ok, Sorted};
                        false -> error
                    end;
                false -> error
            end;
        _ -> error
    end.

manifest_participants(
  {quod_dtx_manifest, ?MANIFEST_VERSION, _, _, _, _, _, _, _, _, _, Rows, _}) ->
    Rows.

-doc "Return the immutable atomic vote deadline, or none for independent claims.".
-spec manifest_deadline(manifest()) -> none | pos_integer().
manifest_deadline(
  {quod_dtx_manifest, ?MANIFEST_VERSION, _, _, _, _, _, _, _, _, _, _, Deadline}) ->
    Deadline.

-doc "Validate a shared manifest and expose its exact immutable bindings.".
-spec manifest_binding(manifest()) -> {ok, map()} | error.
manifest_binding(Manifest) ->
    case valid_manifest(Manifest) of
        true ->
            {quod_dtx_manifest, ?MANIFEST_VERSION, ProofId,
             {Ns, Anchor, Coordinator, Admission}, Nonce, Principal,
             Goal, GoalDigest, Result, ResultDigest, RequestBinding,
             Participants, Deadline} = Manifest,
            {ok, #{proof_id => ProofId, origin => {Ns, Anchor},
                   coordinator => Coordinator, admission => Admission,
                   nonce => Nonce, principal => Principal, goal => Goal,
                   goal_digest => GoalDigest, result => Result,
                   result_digest => ResultDigest, request_binding => RequestBinding,
                   participants => Participants, vote_deadline_ms => Deadline,
                   manifest_digest => manifest_digest_unchecked(Manifest)}};
        false -> error
    end.

-doc """
Authenticate a shared source witness and, when present, exactly one own bundle.

The source attestation binds the manifest to the source executor and its plan
digest; it does not certify origin admission or a vote. A source Vote reuses
that verified attestation, rather than verifying the same signature twice.
The own plan signature and plan/manifest binding are always checked. Foreign
material stays opaque. No caller-supplied preverified flag crosses this API.
""".
-spec attested_group_material(manifest(), attestation(),
                             none | {identity(), <<_:256>>, binary(), attestation()}) ->
          {ok, map()} | error.
attested_group_material(Manifest, SourceAttestation, Bundle) ->
    case source_attestation_binding(Manifest, SourceAttestation) of
        {ok, Binding} ->
            group_bundle_material(Bundle, Manifest, SourceAttestation, Binding);
        error -> error
    end.

group_bundle_material(none, _Manifest, _SourceAttestation, Binding) ->
    {ok, #{group => Binding, plans => #{}}};
group_bundle_material({Target, PlanDigest, PlanBlob, Attestation}, Manifest,
                      SourceAttestation, #{manifest_digest := ManifestDigest} = Binding) ->
    case decode(PlanBlob) of
        {ok, Plan} ->
            ValidAttestation =
                case Attestation of
                    {_, ?ATTESTATION_VERSION, Target, PlanDigest, ManifestDigest,
                     Attestor, _} when Attestation =:= SourceAttestation ->
                        attestation_matches_plan(Target, Plan, PlanDigest, Attestor, Manifest);
                    _ ->
                        verify_plan_attestation_preverified(
                          Target, Plan, Manifest, ManifestDigest, Attestation)
                end,
            case digest(Plan) =:= PlanDigest andalso valid_signed_plan(Plan)
                 andalso ValidAttestation of
                true ->
                    {ok, #{group => Binding, plans => #{Target => Plan},
                           context => manifest_plan_context(Manifest, PlanDigest)}};
                false -> error
            end;
        _ -> error
    end;
group_bundle_material(_, _, _, _) -> error.

source_attestation_binding(
  Manifest,
  {Tag, ?ATTESTATION_VERSION, Origin, PlanDigest, ManifestDigest,
   Coordinator, Signature} = Attestation) ->
    case manifest_binding(Manifest) of
        {ok, #{origin := Origin, coordinator := Coordinator,
               manifest_digest := ManifestDigest,
               participants := Participants} = Binding} ->
            case valid_attestation(Attestation) andalso
                 lists:keyfind(Origin, 1, Participants) =:= {Origin, PlanDigest}
                 andalso quod_identity:verify(
                   Signature,
                   attestation_bytes(Tag, Origin, PlanDigest, ManifestDigest),
                   Coordinator) of
                true -> {ok, Binding};
                false -> error
            end;
        _ -> error
    end;
source_attestation_binding(_, _) -> error.

manifest_proof_id(
  {quod_dtx_manifest, ?MANIFEST_VERSION, ProofId, _, _, _, _, _, _, _, _, _, _}) ->
    ProofId.

manifest_principal(
  {quod_dtx_manifest, ?MANIFEST_VERSION, _, _, _, Principal, _, _, _, _, _, _, _}) ->
    Principal.

manifest_coordinator(
  {quod_dtx_manifest, ?MANIFEST_VERSION, _, Coordinator, _, _, _, _, _, _, _, _, _}) ->
    Coordinator.

manifest_request_binding(
  {quod_dtx_manifest, ?MANIFEST_VERSION, _, _, _, _, _, _, _, _,
   RequestBinding, _, _}) ->
    RequestBinding.

-doc "Reconstruct the public group reference bound by one manifest and its atomic group identity.".
-spec manifest_group_ref(manifest(), <<_:256>>) ->
          {ok, {group, binary(), <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}} |
          error.
manifest_group_ref(Manifest, <<_:256>> = GroupId) ->
    case Manifest of
        {quod_dtx_manifest, ?MANIFEST_VERSION, _,
         {Ns, <<_:256>> = Anchor, <<_:256>> = Coordinator,
          <<_:256>> = Admission}, _, _, _, _, _, _, _, _, _}
          when is_binary(Ns), byte_size(Ns) > 0 ->
            {ok, {group, Ns, Anchor, Coordinator, Admission, GroupId}};
        _ ->
            error
    end;
manifest_group_ref(_Manifest, _GroupId) ->
    error.

within_body_limit(Term) ->
    erlang:external_size(Term) =< ?QUOD_MAX_DTX_BODY_BYTES.

bounded_length(List, Max) ->
    bounded_length(List, Max, 0).

bounded_length([], _Max, Length) -> {ok, Length};
bounded_length([_ | Rest], Max, Length) when Length < Max ->
    bounded_length(Rest, Max, Length + 1);
bounded_length([_ | _], _Max, _Length) -> too_many;
bounded_length(_, _Max, _Length) -> improper.
