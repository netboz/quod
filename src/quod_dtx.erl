-module(quod_dtx).
-moduledoc """
Durable distributed-transaction artifacts and their pure consensus reducer.

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

A scope with an empty diff AND an empty read set seals to `not_material` — it
contributed nothing a commit could depend on. A scope with a **material diff**
that consulted a live reality bridge (`m:quod_predicates` query-class external
predicates) cannot seal: its decisions rest on node-local, non-replayable
state that no later validation can re-prove, so sealing fails
`{non_transactional_dependency, Functor}`. `peer_ready/1` is admissible only
for the exact singleton membership diff that every validator re-proves before
voting; it remains a forbidden live dependency of ordinary content.

## Control protocol

The same module owns the single-version Begin → Prepare → Decision → Finalize
→ Complete codec.  Controls carry atom-safe nested plan bytes, use a separate
signature domain per phase, and are accepted only after exact target, manifest,
plan, reference, and author bindings are verified. Abort Decisions bind one
canonical bounded failure-reason stack; Complete refers to that Decision
without copying the reasons. `reduce/4` is the pure
fold used by live consensus and replay; local apply acknowledgements can open
its proof fence but never change consensus-derived generation state.
""".

-include("quod_proof_limits.hrl").
-include("quod_ledger.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-export([seal_session/2, verify/1, encode/1, decode/1,
         digest/1,
         core/1, target/1, base_height/1, proof_id/1, origin/1,
         principal/1, overlay_generation/1, signer/1,
         participates/1, diff_ops/1, effects_count/1,
         diff_bytes/1, read_check_bytes/1, effects_bytes/1,
         live_bridges_bytes/1,
         material/1, diff/1, read_check/1, effects/1, live_bridges/1,
         transcript/1,
         new_manifest/1, manifest_digest/1,
         encode_manifest/1, decode_manifest/1,
         attest_plan/4, verify_plan_attestation/4,
         encode_attestation/1, decode_attestation/1,
         certified_ref/6, certified_entry_ref/3, validate_certified_ref/1,
         new_begin/2, new_prepare/3, new_decision/4,
         new_finalize/5, new_complete/3,
         encode_record/1, decode_record/1,
         sign_control/6, encode_control/1, decode_control/1,
         verify_control/2, control_kind/1, control_target/1,
         control_body/1, control_metadata/1, prepare_payload/1,
         prepare_matches_begin/2, validate_references/2, event_context/2,
         record_digest/1, group_id/1, decision_failure_reasons/1,
         begin_group_ref/1, begin_recovery_rows/1,
         certified_ref_binding/1, recovery_phase/1, history_phase/2,
         initial_projection/2, valid_projection/1, origin_recovery/1,
         proposal_allowed/2,
         initial_group_history/0, preview/6, reduce/4,
         acknowledge_finalize/4]).

-export_type([plan/0, principal/0, transcript_entry/0,
              manifest/0, attestation/0, certified_ref/0,
              control_record/0, control/0, projection/0,
              group_history/0]).

-define(PLAN_DOMAIN, <<"quod.dtx.plan">>).
-define(PLAN_VERSION, 4).

-define(CONTROL_VERSION, 1).
-define(MANIFEST_VERSION, 1).
-define(ATTESTATION_VERSION, 1).
-define(REF_VERSION, 1).
-define(RECORD_VERSION, 1).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(MANIFEST_DOMAIN, <<"quod.dtx.manifest">>).
-define(ATTESTATION_DOMAIN, <<"quod.dtx.attestation">>).
-define(BEGIN_DOMAIN, <<"quod.dtx.begin">>).
-define(PREPARE_DOMAIN, <<"quod.dtx.prepare">>).
-define(DECISION_DOMAIN, <<"quod.dtx.decision">>).
-define(FINALIZE_DOMAIN, <<"quod.dtx.finalize">>).
-define(COMPLETE_DOMAIN, <<"quod.dtx.complete">>).
-define(PREVIEW_PROOF, <<"quod.dtx.preview">>).

-type identity() :: quod_proof_context:identity().
-type principal() :: {node, <<_:256>>} | {user, <<_:256>>} | anonymous.
-type transcript_entry() ::
        {<<_:128>>, [identity()], binary(),
         allowed | denied, non_neg_integer(), binary(),
         active | complete | error | cancelled}.
-opaque plan() :: {quod_plan, map(), none | <<_:256>>, none | binary()}.

-type manifest() ::
        {quod_dtx_manifest, 1, <<_:256>>,
         {binary(), <<_:256>>, <<_:256>>, <<_:256>>}, <<_:256>>, principal(),
         binary(), <<_:256>>, binary(), <<_:256>>,
         [{identity(), <<_:256>>}]}.
-type attestation() ::
        {quod_dtx_attestation, 1, identity(), <<_:256>>, <<_:256>>,
         <<_:256>>, <<_:512>>}.
-type certified_ref() ::
        {quod_dtx_ref, 1, binary(), <<_:256>>, pos_integer(),
         <<_:256>>, <<_:256>>, binary()}.
-type control_record() ::
        {quod_dtx_begin, 1, manifest(), list()} |
        {quod_dtx_prepare, 1, <<_:256>>, certified_ref(), manifest(),
         <<_:256>>, binary()} |
        {quod_dtx_decision, 1, <<_:256>>, certified_ref(), commit,
         list(), none} |
        {quod_dtx_decision, 1, <<_:256>>, certified_ref(), abort,
         list(), binary()} |
        {quod_dtx_finalize, 1, <<_:256>>, certified_ref(), commit | abort,
         certified_ref() | none, non_neg_integer()} |
        {quod_dtx_complete, 1, <<_:256>>, certified_ref(), list()}.
-type control() ::
        {quod_dtx_control, 1,
         'begin' | prepare | decision | finalize | complete,
         identity(), control_record(), <<_:256>>, <<_:256>>,
         pos_integer(), non_neg_integer(), <<_:512>>}.
-type projection() :: map().
-type group_history() :: map().

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
    case quod_proof_session:check_access(Session) of
        ok ->
            seal_session_checked(
              Session, Target, BaseHeight, ProofId, Origin, Principal);
        {error, _} = Error ->
            Error
    end.

seal_session_checked(Session, Target, BaseHeight, ProofId, Origin, Principal) ->
    Diff = quod_proof_session:local_changes(Session),
    ReadCheck = quod_proof_session:read_set(Session),
    Effects = quod_proof_session:effects(Session),
    Result =
        case {Diff, map_size(ReadCheck), Effects} of
            {[], 0, []} ->
                not_material;
            _ ->
                seal_material(
                  Session, Target, BaseHeight, ProofId, Origin, Principal,
                  Diff, ReadCheck, Effects)
        end,
    %% Extraction and encoding are pure, but the namespace may have committed
    %% Prepare/Finalize while they ran. Never expose a plan (or even classify a
    %% scope as non-material) from a superseded proof generation.
    case quod_proof_session:check_access(Session) of
        ok -> Result;
        {error, _} = Error -> Error
    end.

seal_material(Session, Target, BaseHeight, ProofId, Origin, Principal,
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
                             overlay_generation => Generation,
                             %% Signed alongside the opaque diff so a consumer
                             %% that must not decode foreign vocabulary (the
                             %% proof origin) can still classify every OCC
                             %% participant.
                             diff_ops => length(Diff),
                             read_functors => map_size(ReadCheck),
                             effects_count => length(Effects),
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
          quod_wire_term:encode_canonical(maps:to_list(ReadCheck)),
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
            {error, effect_requires_single_participant};
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
and `transcript` binaries stay opaque until the ontology that owns their
symbols decodes them (`diff/1`, `read_check/1`, `transcript/1`).
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
             principal := Principal, overlay_generation := Generation,
             diff_ops := DiffOps, read_functors := ReadFunctors,
             effects_count := EffectsCount,
             diff := Diff, read_check := ReadCheck, effects := Effects,
             live_bridges := Bridges,
             transcript := Transcript} = Core)
  when map_size(Core) =:= 14,
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
        is_integer(Generation) andalso Generation >= 0 andalso
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

valid_principal({node, <<_:256>>}) -> true;
valid_principal({user, <<_:256>>}) -> true;
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

-doc "SHA-256 of the plan's canonical unsigned bytes — what an envelope binds.".
-spec digest(plan()) -> <<_:256>>.
digest(Plan) -> crypto:hash(sha256, plan_bytes(core(Plan))).

-doc "The signed count of staged write operations; safe on a foreign plan.".
-spec diff_ops(plan()) -> non_neg_integer().
diff_ops(Plan) -> maps:get(diff_ops, core(Plan)).

-doc "Whether this signed plan contributes writes or OCC reads; safe on a foreign plan.".
-spec participates(plan()) -> boolean().
participates(Plan) ->
    diff_ops(Plan) > 0 orelse maps:get(read_functors, core(Plan)) > 0 orelse
        effects_count(Plan) > 0.

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

-doc "The plan's canonical opaque live-bridge marker bytes.".
-spec live_bridges_bytes(plan()) -> binary().
live_bridges_bytes(Plan) -> maps:get(live_bridges, core(Plan)).

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
            case attach_transcript_goals(Transcript, 0, []) of
                {ok, AnnotatedTranscript} ->
                    {ok, {Diff, ReadPairs, Effects, Bridges,
                          AnnotatedTranscript}};
                error ->
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
            case {build_read_check(
                    ReadPairs, maps:get(read_functors, Core), 0, #{}),
                  strip_transcript_goals(AnnotatedTranscript, [])} of
                {{ok, ReadCheck}, {ok, Transcript}} ->
                    case exact_length(Diff, maps:get(diff_ops, Core), 0)
                         andalso exact_length(
                                   Effects, maps:get(effects_count, Core), 0)
                         andalso quod_diff:valid_ops(Diff)
                         andalso quod_diff:valid_read_check(ReadCheck)
                         andalso valid_effects(Effects)
                         andalso valid_live_bridges(Bridges)
                         andalso seal_admissible(
                                   Diff, ReadCheck, Effects, Bridges) =:= ok
                         andalso valid_transcript(Transcript, 0) of
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

build_read_check([], Expected, Expected, Acc) ->
    {ok, Acc};
build_read_check([{Key, Token} | Rest], Expected, Count, Acc)
  when Count < Expected ->
    case maps:is_key(Key, Acc) of
        false -> build_read_check(Rest, Expected, Count + 1,
                                  Acc#{Key => Token});
        true -> error
    end;
build_read_check(_Malformed, _Expected, _Count, _Acc) ->
    error.

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

valid_effects(Effects) ->
    valid_effects(Effects, 0, #{}).

valid_effects([], Count, _Ids) ->
    Count =< ?QUOD_MAX_DIRECT_EFFECTS;
valid_effects([Effect | Rest], Count, Ids)
  when Count < ?QUOD_MAX_DIRECT_EFFECTS ->
    case quod_effect:validate(Effect) of
        true ->
            Id = quod_effect:effect_id(Effect),
            case maps:is_key(Id, Ids) of
                false -> valid_effects(
                           Rest, Count + 1, Ids#{Id => true});
                true -> false
            end;
        false -> false
    end;
valid_effects(_, _Count, _Ids) ->
    false.

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

-doc "Decode the plan's staged write-set. Owner-side only: allocates its atoms.".
-spec diff(plan()) -> [{assert | retract, {term(), term()}}].
diff(Plan) -> material_value(diff, Plan).

-doc "Decode the plan's exact OCC read tokens. Owner-side only.".
-spec read_check(plan()) -> map().
read_check(Plan) -> material_value(read_check, Plan).

-doc "Decode the plan's typed direct effects. Owner-side only.".
-spec effects(plan()) -> [quod_effect:effect()].
effects(Plan) -> material_value(effects, Plan).

-doc "Decode the plan's signed local bridge markers. Owner-side only.".
-spec live_bridges(plan()) -> [{atom(), arity()}].
live_bridges(Plan) -> material_value(live_bridges, Plan).

-doc "Decode the plan's bounded invocation transcript. Owner-side only.".
-spec transcript(plan()) -> [transcript_entry()].
transcript(Plan) -> material_value(transcript, Plan).

material_value(Key, Plan) ->
    case material(Plan) of
        {ok, Material} -> maps:get(Key, Material);
        {error, _} -> error(bad_plan)
    end.

%% ===================================================================
%% Durable multi-ontology control protocol
%% ===================================================================

-doc "Build the one canonical manifest shared by every target attestation.".
-spec new_manifest(map()) -> {ok, manifest()} | {error, term()}.
new_manifest(#{proof_id := <<_:256>> = ProofId,
               coordinator := Coordinator,
               nonce := <<_:256>> = Nonce,
               principal := Principal,
               goal := Goal,
               result := Result,
               participants := Participants} = Input)
  when map_size(Input) =:= 7, is_binary(Goal), is_binary(Result) ->
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
                         crypto:hash(sha256, Result), CanonicalParticipants},
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

-doc "Sign this target's unchanged local plan into one manifest.".
-spec attest_plan(identity(), plan(), manifest(), quod_identity:signer()) ->
          {ok, attestation()} | {error, term()}.
attest_plan(Target, Plan, Manifest,
            #{pubkey := <<_:256>> = Pubkey} = Identity) ->
    case valid_manifest(Manifest) andalso valid_identity(Target) andalso
         valid_signed_plan(Plan) of
        true ->
            ManifestDigest = manifest_digest_unchecked(Manifest),
            PlanDigest = digest(Plan),
            case plan_matches_manifest(
                   Target, Plan, PlanDigest, Manifest) andalso
                 signer(Plan) =:= Pubkey of
                true ->
                    Bytes = attestation_bytes(
                              Target, PlanDigest, ManifestDigest),
                    {ok,
                     {quod_dtx_attestation, ?ATTESTATION_VERSION, Target,
                      PlanDigest, ManifestDigest, Pubkey,
                      quod_identity:sign(Bytes, Identity)}};
                false ->
                    {error, invalid_plan_attestation}
            end;
        false ->
            {error, invalid_plan_attestation}
    end;
attest_plan(_, _, _, _) ->
    {error, invalid_plan_attestation}.

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

verify_plan_attestation_preverified(
  Target, Plan, Manifest, ManifestDigest,
  {quod_dtx_attestation, ?ATTESTATION_VERSION, Target,
   <<_:256>> = PlanDigest, ManifestDigest, <<_:256>> = Attestor,
   <<_:512>> = Signature}) ->
    digest(Plan) =:= PlanDigest andalso
        plan_matches_manifest(Target, Plan, PlanDigest, Manifest) andalso
        signer(Plan) =:= Attestor andalso
        quod_identity:verify(
          Signature,
          attestation_bytes(Target, PlanDigest, ManifestDigest),
          Attestor);
verify_plan_attestation_preverified(_, _, _, _, _) -> false.

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
  {quod_dtx_attestation, ?ATTESTATION_VERSION, Target,
   <<_:256>>, <<_:256>>, <<_:256>>, <<_:512>>}) ->
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
        effects_count(Plan) =:= 0 andalso
        lists:keyfind(Target, 1, manifest_participants(Manifest)) =:=
            {Target, PlanDigest}.

valid_signed_plan({quod_plan, Core, <<_:256>>, <<_:512>>} = Plan) ->
    valid_core(Core) andalso verify(Plan);
valid_signed_plan(_) -> false.

attestation_bytes(Target, PlanDigest, ManifestDigest) ->
    deterministic(
      {?ATTESTATION_DOMAIN, ?ATTESTATION_VERSION,
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
Build the certified DTX reference for one exact committed entry.

The entry must carry a commit certificate for its own slot and reconstructed
block hash. The reference embeds the canonical certificate bytes as finality
evidence and binds the semantic control digest. This is the single pure seam
used by consensus history and ordered Prolog apply; neither consumer rebuilds
or encodes the certificate independently.
""".
-spec certified_entry_ref({binary(), <<_:256>>}, #entry{}, control()) ->
          {ok, certified_ref()} | {error, invalid_certified_entry}.
certified_entry_ref(
  {Ns, <<_:256>> = Anchor},
  #entry{index = Slot,
         cert = #cert{kind = commit, slot = Slot,
                      block_hash = BlockHash} = Cert} = Entry,
  {quod_dtx_control, ?CONTROL_VERSION, _, _, _, _, _, _, _, _} = Control)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_binary(BlockHash), byte_size(BlockHash) =:= 32 ->
    case quod_simplex:block_from_entry(Entry) of
        {ok, Block} ->
            case quod_simplex:block_hash(Block) =:= BlockHash of
                true ->
                    case certified_ref(
                           Ns, Anchor, Slot, BlockHash,
                           record_digest(Control),
                           term_to_binary(Cert, [deterministic])) of
                        {ok, Ref} -> {ok, Ref};
                        {error, _} -> {error, invalid_certified_entry}
                    end;
                false ->
                    {error, invalid_certified_entry}
            end;
        error ->
            {error, invalid_certified_entry}
    end;
certified_entry_ref(_, _, _) ->
    {error, invalid_certified_entry}.

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

-doc "Build a canonical Begin from one manifest and its exact target bundles.".
-spec new_begin(manifest(), list()) ->
          {ok, control_record()} | {error, term()}.
new_begin(Manifest, Bundles) ->
    case canonical_bundles(Bundles) of
        {ok, CanonicalBundles} ->
            Record =
                {quod_dtx_begin, ?RECORD_VERSION, Manifest,
                 CanonicalBundles},
            new_record('begin', Record);
        error ->
            {error, invalid_begin}
    end.

-doc "Build a self-contained Prepare from one exact certified Begin target.".
-spec new_prepare(control_record(), certified_ref(), identity()) ->
          {ok, control_record()} | {error, term()}.
new_prepare(
  {quod_dtx_begin, ?RECORD_VERSION, Manifest, Bundles} = Begin,
  BeginRef, Target) ->
    case valid_record('begin', Begin) andalso within_body_limit(Begin)
         andalso valid_identity(Target) of
        true ->
            GroupId = record_digest_unchecked('begin', Begin),
            case validate_certified_ref(BeginRef) andalso
                 ref_record_digest(BeginRef) =:= GroupId andalso
                 ref_identity(BeginRef) =:= manifest_origin(Manifest) of
                true ->
                    case lists:keyfind(Target, 1, Bundles) of
                        {Target, <<_:256>> = PlanDigest, PlanBlob,
                         _Attestation} ->
                            new_record(
                              prepare,
                              {quod_dtx_prepare, ?RECORD_VERSION,
                               GroupId, BeginRef, Manifest,
                               PlanDigest, PlanBlob});
                        false ->
                            {error, invalid_prepare}
                    end;
                false ->
                    {error, invalid_prepare}
            end;
        false ->
            {error, invalid_prepare}
    end;
new_prepare(_, _, _) ->
    {error, invalid_prepare}.

-doc "Build the origin's unique commit or reason-carrying abort decision.".
-spec new_decision(<<_:256>>, certified_ref(),
                   commit | {abort, nonempty_list(term())}, list()) ->
          {ok, control_record()} | {error, term()}.
new_decision(<<_:256>> = GroupId, BeginRef, commit, PrepareRefs) ->
    case canonical_reference_rows(PrepareRefs) of
        {ok, CanonicalRefs} ->
            new_record(
              decision,
              {quod_dtx_decision, ?RECORD_VERSION, GroupId, BeginRef, commit,
               CanonicalRefs, none});
        error ->
            {error, invalid_decision}
    end;
new_decision(<<_:256>> = GroupId, BeginRef, {abort, Reasons}, PrepareRefs) ->
    case {canonical_reference_rows(PrepareRefs),
          encode_abort_reasons(Reasons)} of
        {{ok, CanonicalRefs}, {ok, ReasonsBlob}} ->
            new_record(
              decision,
              {quod_dtx_decision, ?RECORD_VERSION, GroupId, BeginRef, abort,
               CanonicalRefs, ReasonsBlob});
        _ ->
            {error, invalid_decision}
    end;
new_decision(_, _, _, _) ->
    {error, invalid_decision}.

%% Scope completion permits an empty reason stack, but a durable abort must
%% explain itself.  Shape, count and canonical-byte validation otherwise live
%% solely in quod_wire_term and are shared with the scope wire.
encode_abort_reasons([_ | _] = Reasons) ->
    case quod_wire_term:encode_failure_reasons(Reasons) of
        {ok, _} = Encoded -> Encoded;
        {error, _} -> error
    end;
encode_abort_reasons(_) ->
    error.

decode_abort_reasons(Blob) ->
    case quod_wire_term:decode_failure_reasons(Blob) of
        {ok, [_ | _] = Reasons} -> {ok, Reasons};
        _ -> error
    end.

-doc "Build a participant Finalize; `none` denotes the direct abort path.".
-spec new_finalize(<<_:256>>, certified_ref(), commit | abort,
                   certified_ref() | none, non_neg_integer()) ->
          {ok, control_record()} | {error, term()}.
new_finalize(<<_:256>> = GroupId, DecisionRef, Verdict, PrepareRef,
             AppliedGeneration)
  when (Verdict =:= commit orelse Verdict =:= abort),
       is_integer(AppliedGeneration), AppliedGeneration >= 0,
       AppliedGeneration =< ?MAX_UINT64 ->
    new_record(
      finalize,
      {quod_dtx_finalize, ?RECORD_VERSION, GroupId, DecisionRef, Verdict,
       PrepareRef, AppliedGeneration});
new_finalize(_, _, _, _, _) ->
    {error, invalid_finalize}.

-doc "Build the origin's terminal, target-ordered Complete record.".
-spec new_complete(<<_:256>>, certified_ref(), list()) ->
          {ok, control_record()} | {error, term()}.
new_complete(<<_:256>> = GroupId, DecisionRef, FinalizeRows) ->
    case canonical_finalize_rows(FinalizeRows) of
        {ok, CanonicalRows} ->
            new_record(
              complete,
              {quod_dtx_complete, ?RECORD_VERSION, GroupId, DecisionRef,
               CanonicalRows});
        error ->
            {error, invalid_complete}
    end;
new_complete(_, _, _) ->
    {error, invalid_complete}.

-doc "Encode one exact bounded semantic DTX record; there is no legacy form.".
-spec encode_record(control_record()) ->
          {ok, binary()} |
          {error, {too_large, dtx_body} | {protocol_error, bad_payload}}.
encode_record(Record) ->
    Kind = record_kind(Record),
    case Kind =/= invalid andalso bounded_record_shape(Kind, Record) of
        false ->
            {error, {protocol_error, bad_payload}};
        true ->
            case within_body_limit(Record) of
                false ->
                    {error, {too_large, dtx_body}};
                true ->
                    case valid_record(Kind, Record) of
                        true -> {ok, deterministic(Record)};
                        false -> {error, {protocol_error, bad_payload}}
                    end
            end
    end.

-doc "Atom-safe canonical decode of one fully validated semantic DTX record.".
-spec decode_record(binary()) ->
          {ok, control_record()} |
          {error, {too_large, dtx_body} | {protocol_error, bad_payload}}.
decode_record(Blob)
  when is_binary(Blob), byte_size(Blob) =< ?QUOD_MAX_DTX_BODY_BYTES ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, Record} ->
            Kind = record_kind(Record),
            case deterministic(Record) =:= Blob andalso Kind =/= invalid andalso
                 bounded_record_shape(Kind, Record) andalso
                 valid_record(Kind, Record) of
                true -> {ok, Record};
                false -> {error, {protocol_error, bad_payload}}
            end;
        {error, _} ->
            {error, {protocol_error, bad_payload}}
    end;
decode_record(Blob) when is_binary(Blob) ->
    {error, {too_large, dtx_body}};
decode_record(_) ->
    {error, {protocol_error, bad_payload}}.

new_record(Kind, Record) ->
    case bounded_record_shape(Kind, Record) of
        true ->
            case within_body_limit(Record) of
                true ->
                    case valid_record(Kind, Record) of
                        true -> {ok, Record};
                        false -> {error, invalid_record_reason(Kind)}
                    end;
                false ->
                    {error, {too_large, dtx_body}}
            end;
        false ->
            {error, invalid_record_reason(Kind)}
    end.

invalid_record_reason('begin') -> invalid_begin;
invalid_record_reason(prepare) -> invalid_prepare;
invalid_record_reason(decision) -> invalid_decision;
invalid_record_reason(finalize) -> invalid_finalize;
invalid_record_reason(complete) -> invalid_complete.

-doc "Sign one fixed semantic record for one exact target ontology.".
-spec sign_control(identity(), control_record(), <<_:256>>, pos_integer(),
                   non_neg_integer(), quod_identity:signer()) ->
          {ok, control()} | {error, term()}.
sign_control(Target, Record, <<_:256>> = AuthorAdmission, Sequence,
             SubmittedAt, #{pubkey := <<_:256>> = Author} = Identity)
  when is_integer(Sequence), Sequence > 0, Sequence =< ?MAX_UINT64,
       is_integer(SubmittedAt), SubmittedAt >= 0,
       SubmittedAt =< ?MAX_UINT64 ->
    Kind = record_kind(Record),
    case valid_identity(Target) andalso Kind =/= invalid andalso
         bounded_record_shape(Kind, Record) andalso within_body_limit(Record)
         andalso valid_control_record(Kind, Target, Record) andalso
         begin_author_matches(Kind, Target, Author, AuthorAdmission, Record) of
        true ->
            BodyBlob = deterministic(Record),
            Bytes = control_bytes(
                      Kind, Target, BodyBlob, Author, AuthorAdmission,
                      Sequence, SubmittedAt),
            Control =
                {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, Record,
                 Author, AuthorAdmission, Sequence, SubmittedAt,
                 quod_identity:sign(Bytes, Identity)},
            encode_result(Control);
        false ->
            {error, invalid_control}
    end;
sign_control(_, _, _, _, _, _) ->
    {error, invalid_control}.

-doc "Encode one already-signed control with no compatibility representation.".
-spec encode_control(control()) -> {ok, binary()} | {error, term()}.
encode_control(Control) ->
    case valid_control_shallow(Control) of
        true ->
            Encoded = deterministic(control_wire(Control)),
            case byte_size(Encoded) =< ?QUOD_MAX_DTX_CONTROL_BYTES of
                true -> {ok, Encoded};
                false -> {error, {too_large, dtx_control}}
            end;
        false ->
            {error, {protocol_error, bad_payload}}
    end.

-doc "Atom-safe, bounded and canonical decode of one signed control.".
-spec decode_control(binary()) -> {ok, control()} | {error, term()}.
decode_control(Blob) when is_binary(Blob) ->
    case byte_size(Blob) =< ?QUOD_MAX_DTX_CONTROL_BYTES of
        false ->
            {error, {too_large, dtx_control}};
        true -> decode_control_bounded(Blob)
    end;
decode_control(_) ->
    {error, {protocol_error, bad_payload}}.

decode_control_bounded(Blob) ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_DTX_CONTROL_BYTES) of
        {ok, Wire} ->
            case deterministic(Wire) =:= Blob of
                true -> decode_control_wire(Wire);
                false -> {error, {protocol_error, bad_payload}}
            end;
        {error, too_large} ->
            {error, {too_large, dtx_control}};
        {error, _} ->
            {error, {protocol_error, bad_payload}}
    end.

-doc "Verify the author signature and the exact expected target binding.".
-spec verify_control(identity(), control()) -> boolean().
verify_control(
  ExpectedTarget,
  {quod_dtx_control, ?CONTROL_VERSION, Kind, ExpectedTarget, Record,
   <<_:256>> = Author, <<_:256>> = AuthorAdmission, Sequence, SubmittedAt,
   <<_:512>> = Signature} = Control) ->
    case valid_control_shallow(Control) of
        true ->
            BodyBlob = deterministic(Record),
            quod_identity:verify(
              Signature,
              control_bytes(
                Kind, ExpectedTarget, BodyBlob, Author, AuthorAdmission,
                Sequence, SubmittedAt),
              Author) andalso
                valid_control_record(Kind, ExpectedTarget, Record) andalso
                begin_author_matches(
                  Kind, ExpectedTarget, Author, AuthorAdmission, Record);
        false ->
            false
    end;
verify_control(_, _) ->
    false.

-spec control_kind(control()) -> 'begin' | prepare | decision | finalize | complete.
control_kind({quod_dtx_control, ?CONTROL_VERSION, Kind, _, _, _, _, _, _, _}) ->
    Kind.

-spec control_target(control()) -> identity().
control_target({quod_dtx_control, ?CONTROL_VERSION, _, Target, _, _, _, _, _, _}) ->
    Target.

-spec control_body(control()) -> control_record().
control_body({quod_dtx_control, ?CONTROL_VERSION, Kind, _, BodyBlob,
              _, _, _, _, _}) ->
    true = record_kind(BodyBlob) =:= Kind,
    BodyBlob.

-doc "Return the exact manifest, digest, and opaque plan carried by Prepare.".
-spec prepare_payload(control() | control_record()) ->
          {ok, manifest(), <<_:256>>, binary()} | error.
prepare_payload(
  {quod_dtx_control, ?CONTROL_VERSION, prepare, Target,
   Record, _, _, _, _, _} = Control) ->
    case valid_control_shallow(Control) andalso
         valid_control_record(prepare, Target, Record) of
        true -> prepare_payload_fields(Record);
        false -> error
    end;
prepare_payload(
  {quod_dtx_prepare, ?RECORD_VERSION, _, _, Manifest,
   <<_:256>> = PlanDigest, PlanBlob} = Record)
  when is_binary(PlanBlob) ->
    case valid_record(prepare, Record) of
        true -> {ok, Manifest, PlanDigest, PlanBlob};
        false -> error
    end;
prepare_payload(_) ->
    error.

prepare_payload_fields(
  {quod_dtx_prepare, ?RECORD_VERSION, _, _, Manifest,
   <<_:256>> = PlanDigest, PlanBlob}) ->
    {ok, Manifest, PlanDigest, PlanBlob}.

-doc "Verify that one Prepare copied its context and target plan from this Begin.".
-spec prepare_matches_begin(control() | control_record(),
                            control() | control_record()) -> boolean().
prepare_matches_begin(
  {quod_dtx_control, ?CONTROL_VERSION, prepare, _, Prepare,
   _, _, _, _, _}, Begin) ->
    prepare_matches_begin(Prepare, Begin);
prepare_matches_begin(
  Prepare,
  {quod_dtx_control, ?CONTROL_VERSION, 'begin', _, Begin,
   _, _, _, _, _}) ->
    prepare_matches_begin(Prepare, Begin);
prepare_matches_begin(
  {quod_dtx_prepare, ?RECORD_VERSION, GroupId, BeginRef, Manifest,
   PlanDigest, PlanBlob} = Prepare,
  {quod_dtx_begin, ?RECORD_VERSION, Manifest, Bundles} = Begin) ->
    valid_record(prepare, Prepare) andalso valid_record('begin', Begin)
        andalso prepare_matches_valid_begin(
                  GroupId, BeginRef, PlanDigest, PlanBlob, Begin, Bundles);
prepare_matches_begin(_, _) ->
    false.

prepare_matches_valid_begin(
  GroupId, BeginRef, PlanDigest, PlanBlob, Begin, Bundles) ->
    record_digest_unchecked('begin', Begin) =:= GroupId andalso
        ref_record_digest(BeginRef) =:= GroupId andalso
        lists:any(
          fun({_Target, Digest, Blob, _Attestation}) ->
                  Digest =:= PlanDigest andalso Blob =:= PlanBlob
          end, Bundles).

-doc """
Validate the complete, ordered foreign-evidence set for one DTX control.

Every evidence row has already passed ledger finality verification.  This
pure seam binds each certified reference to the exact referenced control and
then checks the semantic phase chain, so callers never duplicate protocol
tuple knowledge.
""".
-spec validate_references(
        control(),
        [{'begin' | prepare | decision | finalize,
          certified_ref(), control()}]) ->
          ok | {error, invalid_control | invalid_references}.
validate_references(Control, EvidenceRows) ->
    case semantic_control(Control) of
        {ok, Kind, Target, Record} ->
            case validate_reference_chain(
                   Kind, Target, Record, EvidenceRows) of
                true -> ok;
                false -> {error, invalid_references}
            end;
        error ->
            {error, invalid_control}
    end.

validate_reference_chain('begin', _Target, _Begin, []) ->
    true;
validate_reference_chain(
  prepare, _Target,
  {quod_dtx_prepare, ?RECORD_VERSION, _GroupId, BeginRef, _Manifest,
   _PlanDigest, _PlanBlob} = Prepare,
  [{'begin', BeginRef, BeginControl}]) ->
    exact_evidence('begin', BeginRef, BeginControl) andalso
        prepare_matches_valid_begin_controls(Prepare, BeginControl);
validate_reference_chain(
  decision, _Target,
  {quod_dtx_decision, ?RECORD_VERSION, GroupId, BeginRef, Verdict,
   PrepareRows, _Reasons},
  [{'begin', BeginRef, BeginControl} | PrepareEvidence]) ->
    case exact_evidence_record('begin', BeginRef, BeginControl) of
        {ok, _BeginTarget,
         {quod_dtx_begin, ?RECORD_VERSION, Manifest, _Bundles} = Begin} ->
            record_digest_unchecked('begin', Begin) =:= GroupId andalso
                decision_participants_match(
                  Verdict, PrepareRows, Manifest) andalso
                prepare_evidence_matches(
                  PrepareRows, PrepareEvidence, GroupId, BeginRef,
                  BeginControl);
        _ ->
            false
    end;
validate_reference_chain(
  finalize, Target,
  {quod_dtx_finalize, ?RECORD_VERSION, GroupId, DecisionRef, Verdict,
   PrepareRef, _Generation},
  [{decision, DecisionRef, DecisionControl} | PrepareEvidence]) ->
    case exact_evidence_record(decision, DecisionRef, DecisionControl) of
        {ok, _DecisionTarget,
         {quod_dtx_decision, ?RECORD_VERSION, GroupId, BeginRef, Verdict,
          PrepareRows, _Reasons}} ->
            finalize_prepare_evidence_matches(
              Target, GroupId, BeginRef, Verdict, PrepareRef,
              PrepareRows, PrepareEvidence);
        _ ->
            false
    end;
validate_reference_chain(
  complete, _Target,
  {quod_dtx_complete, ?RECORD_VERSION, GroupId, DecisionRef, FinalizeRows},
  [{decision, DecisionRef, DecisionControl} | FinalizeEvidence]) ->
    case exact_evidence_record(decision, DecisionRef, DecisionControl) of
        {ok, _DecisionTarget,
         {quod_dtx_decision, ?RECORD_VERSION, GroupId, _BeginRef, Verdict,
          PrepareRows, _Reasons}} ->
            complete_evidence_matches(
              FinalizeRows, FinalizeEvidence, GroupId, DecisionRef,
              Verdict, PrepareRows) andalso
                complete_participants_match(
                  Verdict, PrepareRows, FinalizeRows);
        _ ->
            false
    end;
validate_reference_chain(_, _, _, _) ->
    false.

semantic_control(
  {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, Record,
   _, _, _, _, _} = Control) ->
    case valid_control_shallow(Control) andalso
         valid_control_record(Kind, Target, Record) of
        true -> {ok, Kind, Target, Record};
        false -> error
    end;
semantic_control(_) ->
    error.

exact_evidence(Kind, Ref, Control) ->
    exact_evidence_record(Kind, Ref, Control) =/= error.

exact_evidence_record(Kind, Ref, Control) ->
    case semantic_control(Control) of
        {ok, Kind, Target, Record} ->
            case validate_certified_ref(Ref) andalso
                 ref_identity(Ref) =:= Target andalso
                 ref_record_digest(Ref) =:=
                     record_digest_unchecked(Kind, Record) of
                true -> {ok, Target, Record};
                false -> error
            end;
        _ ->
            error
    end.

decision_participants_match(Verdict, PrepareRows, Manifest) ->
    PrepareTargets = [Target || {Target, _} <- PrepareRows],
    ManifestTargets = participant_identities(Manifest),
    case Verdict of
        commit -> PrepareTargets =:= ManifestTargets;
        abort -> ordered_subset(PrepareTargets, ManifestTargets)
    end.

prepare_evidence_matches([], [], _GroupId, _BeginRef, _BeginControl) ->
    true;
prepare_evidence_matches(
  [{Target, PrepareRef} | RowRest],
  [{prepare, PrepareRef, PrepareControl} | EvidenceRest],
  GroupId, BeginRef, BeginControl) ->
    case exact_evidence_record(prepare, PrepareRef, PrepareControl) of
        {ok, Target,
         {quod_dtx_prepare, ?RECORD_VERSION, GroupId, BeginRef,
          _Manifest, _PlanDigest, _PlanBlob}} ->
            prepare_matches_valid_begin_controls(
              PrepareControl, BeginControl) andalso
                prepare_evidence_matches(
                  RowRest, EvidenceRest, GroupId, BeginRef, BeginControl);
        _ ->
            false
    end;
prepare_evidence_matches(_, _, _, _, _) ->
    false.

prepare_matches_valid_begin_controls(
  {quod_dtx_control, ?CONTROL_VERSION, prepare, _, Prepare,
   _, _, _, _, _}, BeginControl) ->
    prepare_matches_valid_begin_controls(Prepare, BeginControl);
prepare_matches_valid_begin_controls(
  {quod_dtx_prepare, ?RECORD_VERSION, GroupId, BeginRef, Manifest,
   PlanDigest, PlanBlob},
  {quod_dtx_control, ?CONTROL_VERSION, 'begin', _,
   {quod_dtx_begin, ?RECORD_VERSION, Manifest, Bundles} = Begin,
   _, _, _, _, _}) ->
    prepare_matches_valid_begin(
      GroupId, BeginRef, PlanDigest, PlanBlob, Begin, Bundles).

finalize_prepare_evidence_matches(
  _Target, _GroupId, _BeginRef, abort, none, _Rows, []) ->
    true;
finalize_prepare_evidence_matches(
  Target, GroupId, BeginRef, _Verdict, PrepareRef, PrepareRows,
  [{prepare, PrepareRef, PrepareControl}]) ->
    case exact_evidence_record(prepare, PrepareRef, PrepareControl) of
        {ok, Target,
         {quod_dtx_prepare, ?RECORD_VERSION, GroupId, BeginRef,
          _Manifest, _PlanDigest, _PlanBlob}} ->
            lists:keyfind(Target, 1, PrepareRows) =:= {Target, PrepareRef};
        _ ->
            false
    end;
finalize_prepare_evidence_matches(_, _, _, _, _, _, _) ->
    false.

complete_evidence_matches([], [], _GroupId, _DecisionRef, _Verdict, _Rows) ->
    true;
complete_evidence_matches(
  [{Target, FinalizeRef, Generation} | RowRest],
  [{finalize, FinalizeRef, FinalizeControl} | EvidenceRest],
  GroupId, DecisionRef, Verdict, PrepareRows) ->
    case exact_evidence_record(finalize, FinalizeRef, FinalizeControl) of
        {ok, Target,
         {quod_dtx_finalize, ?RECORD_VERSION, GroupId, DecisionRef, Verdict,
          PrepareRef, Generation}} ->
            finalize_row_matches_decision(
              Target, Verdict, PrepareRef, PrepareRows) andalso
                complete_evidence_matches(
                  RowRest, EvidenceRest, GroupId, DecisionRef,
                  Verdict, PrepareRows);
        _ ->
            false
    end;
complete_evidence_matches(_, _, _, _, _, _) ->
    false.

finalize_row_matches_decision(Target, _Verdict, PrepareRef, PrepareRows)
  when PrepareRef =/= none ->
    lists:keyfind(Target, 1, PrepareRows) =:= {Target, PrepareRef};
finalize_row_matches_decision(_Target, abort, none, _PrepareRows) ->
    true;
finalize_row_matches_decision(_, _, _, _) ->
    false.

complete_participants_match(commit, PrepareRows, FinalizeRows) ->
    [Target || {Target, _} <- PrepareRows] =:=
        [Target || {Target, _, _} <- FinalizeRows];
complete_participants_match(abort, PrepareRows, FinalizeRows) ->
    ordered_subset(
      [Target || {Target, _} <- PrepareRows],
      [Target || {Target, _, _} <- FinalizeRows]).

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
                    {OriginNs, OriginAnchor, _, _} =
                        manifest_coordinator(Manifest),
                    {quod_dtx_manifest, ?MANIFEST_VERSION, ProofId, _, _,
                     Principal, Goal, _, Result, _, _} = Manifest,
                    {ok, #{proof_id => ProofId,
                           origin => {OriginNs, OriginAnchor},
                           principal => Principal,
                           goal => Goal,
                           result => Result,
                           plan_digest => PlanDigest}};
                false ->
                    error
            end;
        false ->
            error
    end.

-doc "Canonical fields needed by the signing journal without opening the record.".
-spec control_metadata(control()) -> map().
control_metadata(
  {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, Record,
   Author, Admission, Sequence, SubmittedAt, _Signature}) ->
    #{kind => Kind, target => Target, body_blob => deterministic(Record),
      author => Author, author_admission => Admission, sequence => Sequence,
      submitted_at => SubmittedAt}.

-doc "Digest of the semantic record only; outer authors may change it safely.".
-spec record_digest(control() | control_record()) -> <<_:256>>.
record_digest({quod_dtx_control, ?CONTROL_VERSION, Kind, _, Record,
               _, _, _, _, _}) ->
    record_digest_unchecked(Kind, Record);
record_digest(Record) ->
    Kind = record_kind(Record),
    true = Kind =/= invalid andalso within_body_limit(Record) andalso
        valid_record(Kind, Record),
    record_digest_unchecked(Kind, Record).

record_digest_unchecked(Kind, Record) ->
    BodyBlob = deterministic(Record),
    crypto:hash(sha256, deterministic({record_domain(Kind), 1, BodyBlob})).

-doc "Stable identity of one semantic Begin, independent of its outer author.".
-spec group_id(control() | control_record()) -> <<_:256>>.
group_id({quod_dtx_control, ?CONTROL_VERSION, 'begin', _, _, _, _, _, _, _} =
           Control) ->
    record_digest(Control);
group_id({quod_dtx_control, ?CONTROL_VERSION, _, _, Record, _, _, _, _, _}) ->
    record_group_id(Record);
group_id({quod_dtx_begin, ?RECORD_VERSION, _, _} = Begin) ->
    record_digest(Begin);
group_id({quod_dtx_prepare, ?RECORD_VERSION, GroupId, _, _, _, _}) -> GroupId;
group_id({quod_dtx_decision, ?RECORD_VERSION, GroupId, _, _, _, _}) -> GroupId;
group_id({quod_dtx_finalize, ?RECORD_VERSION, GroupId, _, _, _, _}) -> GroupId;
group_id({quod_dtx_complete, ?RECORD_VERSION, GroupId, _, _}) -> GroupId.

-doc "Return the durable public reference fixed by one validated semantic Begin.".
-spec begin_group_ref(control_record()) ->
          {ok, {group, binary(), <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}} |
          error.
begin_group_ref(
  {quod_dtx_begin, ?RECORD_VERSION,
   {quod_dtx_manifest, ?MANIFEST_VERSION, _ProofId,
    {Ns, <<_:256>> = Anchor, <<_:256>> = Coordinator,
     <<_:256>> = Admission},
    _Nonce, _Principal, _Goal, _GoalDigest, _Result, _ResultDigest,
    _Participants}, _Bundles} = Begin)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    case valid_record('begin', Begin) andalso within_body_limit(Begin) of
        true ->
            {ok, {group, Ns, Anchor, Coordinator, Admission,
                  record_digest(Begin)}};
        false ->
            error
    end;
begin_group_ref(_) ->
    error.

-doc "Validated canonical target/plan rows needed to redrive one Begin.".
-spec begin_recovery_rows(control_record()) ->
          {ok, identity(), <<_:256>>, [{identity(), binary()}]} | error.
begin_recovery_rows(
  {quod_dtx_begin, ?RECORD_VERSION,
   {quod_dtx_manifest, ?MANIFEST_VERSION, _ProofId,
    {Ns, <<_:256>> = Anchor, _Coordinator, _Admission},
    _Nonce, _Principal, _Goal, _GoalDigest, _Result, _ResultDigest,
    _Participants}, Bundles} = Begin)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    case valid_record('begin', Begin) andalso within_body_limit(Begin) of
        true ->
            {ok, {Ns, Anchor}, record_digest(Begin),
             [{Target, PlanBlob}
              || {Target, _PlanDigest, PlanBlob, _Attestation} <- Bundles]};
        false ->
            error
    end;
begin_recovery_rows(_) ->
    error.

-doc "Validated Decision/Finalize fields consumed by the pure recovery driver.".
-spec recovery_phase(control_record()) ->
          {ok, map()} | error.
recovery_phase(
  {quod_dtx_decision, ?RECORD_VERSION, GroupId, BeginRef, Verdict,
   PrepareRows, _ReasonsBlob} = Decision) ->
    case valid_record(decision, Decision) andalso within_body_limit(Decision) of
        true ->
            Reasons = case decision_failure_reasons(Decision) of
                          none -> none;
                          {ok, Stack} -> Stack
                      end,
            {ok, #{kind => decision, group_id => GroupId,
                   begin_ref => BeginRef, verdict => Verdict,
                   prepare_rows => PrepareRows, reasons => Reasons}};
        false ->
            error
    end;
recovery_phase(
  {quod_dtx_finalize, ?RECORD_VERSION, GroupId, DecisionRef, Verdict,
   PrepareRef, Generation} = Finalize) ->
    case valid_record(finalize, Finalize) andalso within_body_limit(Finalize) of
        true ->
            {ok, #{kind => finalize, group_id => GroupId,
                   decision_ref => DecisionRef, verdict => Verdict,
                   prepare_ref => PrepareRef, generation => Generation}};
        false ->
            error
    end;
recovery_phase(_) ->
    error.

-doc "The exact bounded reason stack carried by an abort Decision.".
-spec decision_failure_reasons(control() | control_record()) ->
          none | {ok, nonempty_list(term())}.
decision_failure_reasons(
  {quod_dtx_control, ?CONTROL_VERSION, decision, _, Record,
   _, _, _, _, _}) ->
    decision_failure_reasons(Record);
decision_failure_reasons(
  {quod_dtx_decision, ?RECORD_VERSION, _, _, commit, _, none}) ->
    none;
decision_failure_reasons(
  {quod_dtx_decision, ?RECORD_VERSION, _, _, abort, _, ReasonsBlob}) ->
    decode_abort_reasons(ReasonsBlob).

valid_control_shallow(
  {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, Record,
   <<_:256>>, <<_:256>>, Sequence, SubmittedAt, <<_:512>>})
  when is_integer(Sequence), Sequence > 0, Sequence =< ?MAX_UINT64,
       is_integer(SubmittedAt), SubmittedAt >= 0,
       SubmittedAt =< ?MAX_UINT64 ->
    valid_identity(Target) andalso record_kind(Record) =:= Kind andalso
        bounded_record_shape(Kind, Record) andalso within_body_limit(Record)
        andalso valid_record_structure(Kind, Record);
valid_control_shallow(_) -> false.

encode_result(Control) ->
    case encode_control(Control) of
        {ok, _} -> {ok, Control};
        {error, _} = Error -> Error
    end.

control_wire(
  {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, Record,
   Author, AuthorAdmission, Sequence, SubmittedAt, Signature}) ->
    {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, deterministic(Record),
     Author, AuthorAdmission, Sequence, SubmittedAt, Signature}.

decode_control_wire(
  {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, BodyBlob,
   <<_:256>> = Author, <<_:256>> = AuthorAdmission, Sequence, SubmittedAt,
   <<_:512>> = Signature})
  when is_binary(BodyBlob), byte_size(BodyBlob) =< ?QUOD_MAX_DTX_BODY_BYTES,
       is_integer(Sequence), Sequence > 0, Sequence =< ?MAX_UINT64,
       is_integer(SubmittedAt), SubmittedAt >= 0,
       SubmittedAt =< ?MAX_UINT64 ->
    case valid_identity(Target) andalso valid_kind(Kind) of
        true ->
            case decode_control_body(Kind, BodyBlob) of
                {ok, Record} ->
                    {ok,
                     {quod_dtx_control, ?CONTROL_VERSION, Kind, Target,
                      Record, Author, AuthorAdmission, Sequence, SubmittedAt,
                      Signature}};
                {error, _} = Error -> Error
            end;
        false ->
            {error, {protocol_error, bad_payload}}
    end;
decode_control_wire(_) ->
    {error, {protocol_error, bad_payload}}.

decode_control_body(Kind, BodyBlob) when is_binary(BodyBlob) ->
    case quod_safe_term:decode(BodyBlob, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, Record} ->
            case deterministic(Record) =:= BodyBlob andalso
                 record_kind(Record) =:= Kind andalso
                 bounded_record_shape(Kind, Record) andalso
                 valid_record_structure(Kind, Record) of
                true -> {ok, Record};
                false -> {error, {protocol_error, bad_payload}}
            end;
        {error, _} ->
            {error, {protocol_error, bad_payload}}
    end.

control_bytes(Kind, Target, BodyBlob, Author, AuthorAdmission,
              Sequence, SubmittedAt) ->
    deterministic(
      {control_domain(Kind), ?CONTROL_VERSION, Target, BodyBlob,
       Author, AuthorAdmission, Sequence, SubmittedAt}).

control_domain('begin') -> <<"quod.dtx.control.begin">>;
control_domain(prepare) -> <<"quod.dtx.control.prepare">>;
control_domain(decision) -> <<"quod.dtx.control.decision">>;
control_domain(finalize) -> <<"quod.dtx.control.finalize">>;
control_domain(complete) -> <<"quod.dtx.control.complete">>.

valid_kind('begin') -> true;
valid_kind(prepare) -> true;
valid_kind(decision) -> true;
valid_kind(finalize) -> true;
valid_kind(complete) -> true;
valid_kind(_) -> false.

record_domain('begin') -> ?BEGIN_DOMAIN;
record_domain(prepare) -> ?PREPARE_DOMAIN;
record_domain(decision) -> ?DECISION_DOMAIN;
record_domain(finalize) -> ?FINALIZE_DOMAIN;
record_domain(complete) -> ?COMPLETE_DOMAIN.

record_kind({quod_dtx_begin, ?RECORD_VERSION, _, _}) -> 'begin';
record_kind({quod_dtx_prepare, ?RECORD_VERSION, _, _, _, _, _}) -> prepare;
record_kind({quod_dtx_decision, ?RECORD_VERSION, _, _, _, _, _}) -> decision;
record_kind({quod_dtx_finalize, ?RECORD_VERSION, _, _, _, _, _}) -> finalize;
record_kind({quod_dtx_complete, ?RECORD_VERSION, _, _, _}) -> complete;
record_kind(_) -> invalid.

%% Cheap shape/cardinality pass used before canonical encoding, nested plan
%% decode, hashing, or signature work.  Every list is rejected after at most
%% nine cells; no hostile list is sorted or traversed without that proof.
bounded_record_shape(
  'begin', {quod_dtx_begin, ?RECORD_VERSION, Manifest, Bundles}) ->
    bounded_manifest_shape(Manifest) andalso
        bounded_bundle_shape(Bundles);
bounded_record_shape(
  prepare, {quod_dtx_prepare, ?RECORD_VERSION, <<_:256>>, Ref, Manifest,
            <<_:256>>, PlanBlob}) ->
    validate_certified_ref(Ref) andalso bounded_manifest_shape(Manifest)
        andalso is_binary(PlanBlob) andalso
        byte_size(PlanBlob) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES;
bounded_record_shape(
  decision, {quod_dtx_decision, ?RECORD_VERSION, <<_:256>>, Ref, Verdict,
             Rows, ReasonsBlob}) ->
    validate_certified_ref(Ref) andalso valid_verdict(Verdict) andalso
        bounded_proper_list(Rows, ?QUOD_MAX_DTX_PARTICIPANTS) andalso
        bounded_decision_reasons(Verdict, ReasonsBlob);
bounded_record_shape(
  finalize, {quod_dtx_finalize, ?RECORD_VERSION, <<_:256>>, DecisionRef,
             Verdict, PrepareRef, Generation}) ->
    validate_certified_ref(DecisionRef) andalso valid_verdict(Verdict) andalso
        (PrepareRef =:= none orelse validate_certified_ref(PrepareRef)) andalso
        is_integer(Generation) andalso Generation >= 0 andalso
        Generation =< ?MAX_UINT64;
bounded_record_shape(
  complete, {quod_dtx_complete, ?RECORD_VERSION, <<_:256>>, DecisionRef,
             Rows}) ->
    validate_certified_ref(DecisionRef) andalso
        bounded_proper_list(Rows, ?QUOD_MAX_DTX_PARTICIPANTS);
bounded_record_shape(_, _) -> false.

bounded_manifest_shape(
  {quod_dtx_manifest, ?MANIFEST_VERSION, <<_:256>>,
   {Ns, <<_:256>>, <<_:256>>, <<_:256>>}, <<_:256>>, Principal,
   Goal, <<_:256>>, Result, <<_:256>>, Participants}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0 andalso
        valid_principal(Principal) andalso is_binary(Goal) andalso
        byte_size(Goal) =< ?QUOD_MAX_TOPLEVEL_GOAL_BYTES andalso
        is_binary(Result) andalso
        byte_size(Result) =< ?QUOD_MAX_DURABLE_RESULT_BYTES andalso
        case bounded_length(Participants, ?QUOD_MAX_DTX_PARTICIPANTS) of
            {ok, Length} when Length >= 2 -> true;
            _ -> false
        end;
bounded_manifest_shape(_) -> false.

bounded_bundle_shape(Bundles) ->
    case bounded_length(Bundles, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, Length} when Length >= 2 ->
            lists:all(
              fun({Target, <<_:256>>, PlanBlob,
                   {quod_dtx_attestation, ?ATTESTATION_VERSION, _, _, _,
                    <<_:256>>, <<_:512>>}}) ->
                      valid_identity(Target) andalso is_binary(PlanBlob) andalso
                          byte_size(PlanBlob) =<
                              ?QUOD_MAX_PLAN_ENVELOPE_BYTES;
                 (_) -> false
              end, Bundles);
        _ -> false
    end.

phase_target_matches(
  'begin', {Ns, Anchor},
  {quod_dtx_begin, ?RECORD_VERSION, Manifest, _}) ->
    {OriginNs, OriginAnchor, _, _} = manifest_coordinator(Manifest),
    {OriginNs, OriginAnchor} =:= {Ns, Anchor};
phase_target_matches(
  decision, Target,
  {quod_dtx_decision, ?RECORD_VERSION, _, BeginRef, _, _, _}) ->
    ref_identity(BeginRef) =:= Target;
phase_target_matches(
  finalize, Target,
  {quod_dtx_finalize, ?RECORD_VERSION, _, _, _, none, _}) ->
    valid_identity(Target);
phase_target_matches(
  finalize, Target,
  {quod_dtx_finalize, ?RECORD_VERSION, _, _, _, PrepareRef, _}) ->
    ref_identity(PrepareRef) =:= Target;
phase_target_matches(
  complete, Target,
  {quod_dtx_complete, ?RECORD_VERSION, _, DecisionRef, _}) ->
    ref_identity(DecisionRef) =:= Target;
phase_target_matches(_, _, _) -> false.

valid_control_record(prepare, Target,
                     {quod_dtx_prepare, ?RECORD_VERSION,
                      <<_:256>> = GroupId, BeginRef,
                      Manifest, <<_:256>> = PlanDigest, PlanBlob} = Record) ->
    valid_prepare_record(
      Target, Record, GroupId, BeginRef, Manifest, PlanDigest, PlanBlob);
valid_control_record(Kind, Target, Record) ->
    valid_record(Kind, Record) andalso
        phase_target_matches(Kind, Target, Record).

valid_record_structure(
  'begin', {quod_dtx_begin, ?RECORD_VERSION, Manifest, Bundles}) ->
    valid_manifest_structure(Manifest) andalso
        valid_bundle_structure(Manifest, Bundles);
valid_record_structure(
  prepare,
  {quod_dtx_prepare, ?RECORD_VERSION, <<_:256>> = GroupId, BeginRef,
   Manifest, <<_:256>>, PlanBlob}) ->
    validate_certified_ref(BeginRef) andalso
        ref_record_digest(BeginRef) =:= GroupId andalso
        valid_manifest_structure(Manifest) andalso
        is_binary(PlanBlob) andalso
        byte_size(PlanBlob) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES;
valid_record_structure(
  decision,
  {quod_dtx_decision, ?RECORD_VERSION, <<_:256>> = GroupId, BeginRef,
   Verdict, PrepareRefs, ReasonsBlob}) ->
    validate_certified_ref(BeginRef) andalso
        ref_record_digest(BeginRef) =:= GroupId andalso
        valid_verdict(Verdict) andalso valid_reference_rows(PrepareRefs) andalso
        (Verdict =:= abort orelse PrepareRefs =/= []) andalso
        valid_decision_reasons(Verdict, ReasonsBlob);
valid_record_structure(
  finalize,
  {quod_dtx_finalize, ?RECORD_VERSION, <<_:256>>, DecisionRef, Verdict,
   PrepareRef, AppliedGeneration}) ->
    validate_certified_ref(DecisionRef) andalso
        is_integer(AppliedGeneration) andalso AppliedGeneration >= 0 andalso
        AppliedGeneration =< ?MAX_UINT64 andalso
        valid_finalize_prepare(Verdict, PrepareRef);
valid_record_structure(
  complete,
  {quod_dtx_complete, ?RECORD_VERSION, <<_:256>>, DecisionRef,
   FinalizeRows}) ->
    validate_certified_ref(DecisionRef) andalso
        valid_finalize_rows(FinalizeRows);
valid_record_structure(_, _) -> false.

valid_manifest_structure(Manifest) ->
    bounded_manifest_shape(Manifest) andalso
        valid_identity_digest_rows(manifest_participants(Manifest), none).

valid_bundle_structure(Manifest, Bundles) ->
    Participants = manifest_participants(Manifest),
    ManifestDigest = manifest_digest_unchecked(Manifest),
    case bounded_length(Bundles, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, _} ->
            valid_bundle_structure(
              Bundles, Participants, ManifestDigest);
        _ -> false
    end.

valid_bundle_structure([], [], _ManifestDigest) -> true;
valid_bundle_structure(
  [{Target, PlanDigest, PlanBlob, Attestation} | BundleRest],
  [{Target, PlanDigest} | ParticipantRest], ManifestDigest)
  when is_binary(PlanBlob),
       byte_size(PlanBlob) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES ->
    valid_attestation_shape(
      Attestation, Target, PlanDigest, ManifestDigest) andalso
        valid_bundle_structure(
          BundleRest, ParticipantRest, ManifestDigest);
valid_bundle_structure(_, _, _) -> false.

valid_record('begin', {quod_dtx_begin, ?RECORD_VERSION, Manifest, Bundles}) ->
    valid_manifest(Manifest) andalso valid_bundles(Manifest, Bundles);
valid_record(prepare,
             {quod_dtx_prepare, ?RECORD_VERSION, <<_:256>> = GroupId, BeginRef,
              Manifest, <<_:256>> = PlanDigest, PlanBlob} = Record)
  when is_binary(PlanBlob),
       byte_size(PlanBlob) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES ->
    valid_prepare_record(
      any, Record, GroupId, BeginRef, Manifest, PlanDigest, PlanBlob);
valid_record(decision,
             Record) ->
    valid_record_structure(decision, Record);
valid_record(finalize, Record) ->
    valid_record_structure(finalize, Record);
valid_record(complete, Record) ->
    valid_record_structure(complete, Record);
valid_record(_, _) -> false.

valid_prepare_record(ExpectedTarget, Record, GroupId, BeginRef, Manifest,
                     PlanDigest, PlanBlob) ->
    validate_certified_ref(BeginRef) andalso
        ref_record_digest(BeginRef) =:= GroupId andalso
        valid_manifest(Manifest) andalso within_body_limit(Record) andalso
        manifest_origin(Manifest) =:= ref_identity(BeginRef) andalso
        case decode(PlanBlob) of
            {ok, Plan} ->
                Target = target(Plan),
                (ExpectedTarget =:= any orelse ExpectedTarget =:= Target)
                    andalso digest(Plan) =:= PlanDigest
                    andalso valid_signed_plan(Plan)
                    andalso plan_matches_manifest(
                              Target, Plan, PlanDigest, Manifest);
            {error, _} -> false
        end.

valid_manifest(
  {quod_dtx_manifest, ?MANIFEST_VERSION, <<_:256>>,
   {OriginNs, <<_:256>>, <<_:256>>, <<_:256>>}, <<_:256>>, Principal,
   Goal, <<_:256>> = GoalDigest, Result, <<_:256>> = ResultDigest,
   Participants})
  when is_binary(OriginNs), byte_size(OriginNs) > 0,
       is_binary(Goal), byte_size(Goal) =< ?QUOD_MAX_TOPLEVEL_GOAL_BYTES,
       is_binary(Result), byte_size(Result) =< ?QUOD_MAX_DURABLE_RESULT_BYTES ->
    valid_principal(Principal) andalso
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
        {ok, Length} when Length >= 2 ->
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
        {ok, Length} when Length >= 2 ->
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

canonical_bundles(Bundles) ->
    case bounded_bundle_shape(Bundles) of
        true ->
            Sorted = lists:keysort(1, Bundles),
            case strict_bundle_identities(Sorted, none) of
                true -> {ok, Sorted};
                false -> error
            end;
        false -> error
    end.

strict_bundle_identities([], _Previous) -> true;
strict_bundle_identities([{Identity, _, _, _} | Rest], Previous)
  when Previous =:= none; Previous < Identity ->
    strict_bundle_identities(Rest, Identity);
strict_bundle_identities(_, _) -> false.

canonical_reference_rows(Rows) ->
    case bounded_length(Rows, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, _} ->
            case lists:all(
                   fun({Identity, Ref}) ->
                           valid_identity(Identity) andalso
                               validate_certified_ref(Ref) andalso
                               ref_identity(Ref) =:= Identity;
                      (_) -> false
                   end, Rows) of
                true ->
                    Sorted = lists:keysort(1, Rows),
                    case valid_reference_rows(Sorted, none) of
                        true -> {ok, Sorted};
                        false -> error
                    end;
                false -> error
            end;
        _ -> error
    end.

canonical_finalize_rows(Rows) ->
    case bounded_length(Rows, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, Length} when Length >= 2 ->
            case lists:all(
                   fun({Identity, Ref, Generation}) ->
                           valid_identity(Identity) andalso
                               validate_certified_ref(Ref) andalso
                               ref_identity(Ref) =:= Identity andalso
                               is_integer(Generation) andalso Generation >= 0
                               andalso Generation =< ?MAX_UINT64;
                      (_) -> false
                   end, Rows) of
                true ->
                    Sorted = lists:keysort(1, Rows),
                    case valid_finalize_rows(Sorted, none) of
                        true -> {ok, Sorted};
                        false -> error
                    end;
                false -> error
            end;
        _ -> error
    end.

valid_bundles(Manifest, Bundles) ->
    Participants = manifest_participants(Manifest),
    case bounded_length(Bundles, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, _Length} ->
            ManifestDigest = manifest_digest_unchecked(Manifest),
            valid_bundles(Bundles, Participants, Manifest, ManifestDigest);
        _ ->
            false
    end.

valid_bundles([], [], _Manifest, _ManifestDigest) -> true;
valid_bundles(
  [{Target, <<_:256>> = PlanDigest, PlanBlob, Attestation} | BundleRest],
  [{Target, PlanDigest} | ParticipantRest], Manifest, ManifestDigest)
  when is_binary(PlanBlob),
       byte_size(PlanBlob) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES ->
    valid_attestation_shape(
      Attestation, Target, PlanDigest, ManifestDigest)
        andalso valid_bundle_plan(
                  Target, PlanBlob, Manifest, ManifestDigest,
                  Attestation)
        andalso valid_bundles(
                  BundleRest, ParticipantRest, Manifest, ManifestDigest);
valid_bundles(_, _, _, _) -> false.

valid_bundle_plan(Target, PlanBlob, Manifest, ManifestDigest, Attestation) ->
    case decode(PlanBlob) of
        {ok, Plan} ->
            valid_signed_plan(Plan) andalso
                verify_plan_attestation_preverified(
                  Target, Plan, Manifest, ManifestDigest, Attestation);
        {error, _} ->
            false
    end.

valid_attestation_shape(
  {quod_dtx_attestation, ?ATTESTATION_VERSION, Target, PlanDigest,
   ManifestDigest, <<_:256>>, <<_:512>>}, Target, PlanDigest, ManifestDigest) ->
    valid_identity(Target);
valid_attestation_shape(_, _, _, _) -> false.

manifest_participants(
  {quod_dtx_manifest, ?MANIFEST_VERSION, _, _, _, _, _, _, _, _, Rows}) ->
    Rows.

manifest_proof_id(
  {quod_dtx_manifest, ?MANIFEST_VERSION, ProofId, _, _, _, _, _, _, _, _}) ->
    ProofId.

manifest_principal(
  {quod_dtx_manifest, ?MANIFEST_VERSION, _, _, _, Principal, _, _, _, _, _}) ->
    Principal.

manifest_coordinator(
  {quod_dtx_manifest, ?MANIFEST_VERSION, _, Coordinator, _, _, _, _, _, _, _}) ->
    Coordinator.

manifest_origin(Manifest) ->
    {Ns, Anchor, _Coordinator, _Admission} = manifest_coordinator(Manifest),
    {Ns, Anchor}.

begin_author_matches('begin', {Ns, Anchor}, Author, Admission,
                     {quod_dtx_begin, ?RECORD_VERSION, Manifest, _}) ->
    manifest_coordinator(Manifest) =:= {Ns, Anchor, Author, Admission};
begin_author_matches(Kind, _Target, _Author, _Admission, _Record) ->
    Kind =/= 'begin'.

valid_verdict(commit) -> true;
valid_verdict(abort) -> true;
valid_verdict(_) -> false.

bounded_decision_reasons(commit, none) -> true;
bounded_decision_reasons(abort, Blob) ->
    is_binary(Blob) andalso
        byte_size(Blob) =< ?ERLOG_MAX_FAILURE_REASONS_BYTES;
bounded_decision_reasons(_, _) -> false.

valid_decision_reasons(commit, none) -> true;
valid_decision_reasons(abort, Blob) ->
    case decode_abort_reasons(Blob) of
        {ok, [_ | _]} -> true;
        error -> false
    end;
valid_decision_reasons(_, _) -> false.

valid_reference_rows(Rows) ->
    case bounded_length(Rows, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, _Length} ->
            valid_reference_rows(Rows, none);
        _ -> false
    end.

valid_reference_rows([], _Previous) -> true;
valid_reference_rows([{Identity, Ref} | Rest], Previous)
  when Previous =:= none; Previous < Identity ->
    valid_identity(Identity) andalso validate_certified_ref(Ref) andalso
        ref_identity(Ref) =:= Identity andalso
        valid_reference_rows(Rest, Identity);
valid_reference_rows(_, _) -> false.

valid_finalize_prepare(commit, Ref) -> validate_certified_ref(Ref);
valid_finalize_prepare(abort, none) -> true;
valid_finalize_prepare(abort, Ref) -> validate_certified_ref(Ref);
valid_finalize_prepare(_, _) -> false.

valid_finalize_rows(Rows) ->
    case bounded_length(Rows, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, Length} when Length >= 2 ->
            valid_finalize_rows(Rows, none);
        _ -> false
    end.

valid_finalize_rows([], _Previous) -> true;
valid_finalize_rows([{Identity, Ref, Generation} | Rest], Previous)
  when (Previous =:= none orelse Previous < Identity),
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    valid_identity(Identity) andalso validate_certified_ref(Ref) andalso
        ref_identity(Ref) =:= Identity andalso
        valid_finalize_rows(Rest, Identity);
valid_finalize_rows(_, _) -> false.

within_body_limit(Term) ->
    erlang:external_size(Term) =< ?QUOD_MAX_DTX_BODY_BYTES.

%% ===================================================================
%% Pure committed-history reducer
%% ===================================================================

-doc "Initial per-ontology DTX gate projection.".
-spec initial_projection(identity(), non_neg_integer()) -> projection().
initial_projection(Target, Generation)
  when is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    true = valid_identity(Target),
    #{target => Target, active => none, consensus_lock => open,
      proof_fence => open, generation => Generation}.

-doc "Return the exact active origin Begin reference needed to restart recovery.".
-spec origin_recovery(projection()) ->
          none | {active, <<_:256>>, certified_ref()}.
origin_recovery(Projection) ->
    case valid_projection(Projection) of
        true ->
            case maps:get(active, Projection) of
                #{group_id := GroupId,
                  origin := #{begin_ref := BeginRef}} ->
                    {active, GroupId, BeginRef};
                _ ->
                    none
            end;
        false ->
            none
    end.

-doc "Whether one already-validated retained control is the next phase this projection may propose.".
-spec proposal_allowed(control_record(), projection()) -> boolean().
proposal_allowed(
  {quod_dtx_begin, ?RECORD_VERSION, _, _},
  #{active := none, consensus_lock := open}) ->
    true;
proposal_allowed(
  {quod_dtx_prepare, ?RECORD_VERSION, <<_:256>>, _, _, _, _},
  #{active := none, consensus_lock := open}) ->
    true;
proposal_allowed(
  {quod_dtx_prepare, ?RECORD_VERSION, <<_:256>> = GroupId, _, _, _, _},
  #{active := #{group_id := GroupId, origin := Origin, participant := none},
    consensus_lock := open}) ->
    Origin =/= none;
proposal_allowed(
  {quod_dtx_decision, ?RECORD_VERSION, <<_:256>> = GroupId,
   _, _, _, _},
  #{active := #{group_id := GroupId,
                origin := #{phase := begun}},
    consensus_lock := Lock}) ->
    Lock =:= open orelse Lock =:= {locked, GroupId};
proposal_allowed(
  {quod_dtx_finalize, ?RECORD_VERSION, <<_:256>>, _, abort, none, _},
  _Projection) ->
    %% A direct abort is a metadata-only tombstone.  The reducer proves its
    %% Decision binding and deliberately leaves any unrelated lock untouched.
    true;
proposal_allowed(
  {quod_dtx_finalize, ?RECORD_VERSION, <<_:256>> = GroupId,
   _, _, _PrepareRef, _},
  #{active := #{group_id := GroupId,
                participant := #{phase := prepared}},
    consensus_lock := {locked, GroupId}}) ->
    true;
proposal_allowed(
  {quod_dtx_complete, ?RECORD_VERSION, <<_:256>> = GroupId, _, _},
  #{active := #{group_id := GroupId, participant := none,
                origin := #{phase := {decided, _}}},
    consensus_lock := open}) ->
    true;
proposal_allowed(_Record, _Projection) ->
    false.

-doc "Empty exact history for one GroupId (at most five records).".
-spec initial_group_history() -> group_history().
initial_group_history() ->
    #{group_id => none, records => #{}}.

-doc "Return one exact committed phase reference from a validated group history.".
-spec history_phase('begin' | prepare | decision | finalize | complete,
                    group_history()) ->
          not_found | {ok, certified_ref()}.
history_phase(Kind, History) ->
    case (Kind =:= 'begin' orelse valid_kind(Kind)) andalso
         valid_group_history(History) of
        true ->
            case maps:find(Kind, maps:get(records, History)) of
                {ok, #{ref := Ref}} -> {ok, Ref};
                error -> not_found
            end;
        false ->
            not_found
    end.

-doc """
Dry-run one prospective control against an exact parent history and projection.

The candidate has no commit certificate yet, so this function constructs the
private prospective reference needed by the shared reducer from its exact
target, slot, block hash, and semantic record digest.  It then returns
`reduce/4`'s result unchanged.  The successful history and projection are
validation-only: they contain that prospective reference and must never be
persisted or installed.  Committed apply calls `reduce/4` again with the real
certificate-derived reference.

Outer control-signature, author-admission, sequence, and foreign-history checks
remain the caller's responsibility, exactly as for `reduce/4`.
""".
-spec preview(control(), identity(), pos_integer(), <<_:256>>,
              group_history(), projection()) ->
          {ok, group_history(), projection(), list()} | {error, term()}.
preview(Control, {Ns, <<_:256>> = Anchor}, Slot,
        <<_:256>> = BlockHash, History, Projection)
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64 ->
    case valid_control_shallow(Control) of
        true ->
            {ok, Ref} = certified_ref(
                          Ns, Anchor, Slot, BlockHash,
                          record_digest(Control), ?PREVIEW_PROOF),
            reduce(Control, Ref, History, Projection);
        false ->
            {error, {invalid_transition, malformed_state}}
    end;
preview(_Control, _Target, _Slot, _BlockHash, _History, _Projection) ->
    {error, {invalid_transition, malformed_state}}.

-doc """
Fold one already-certified control through the namespace's monotonic DTX state.

The caller has already verified the outer control and every referenced
certified record/finality proof, including phase, group, and verdict bindings.
This reducer deliberately performs only bounded structural and state-transition
checks; it is not the finality-verification boundary.

`History` is the exact (possibly disk-recovered) history for this control's
GroupId, not a global cache. Keeping that lookup outside the reducer avoids an
unbounded used-group table while still making evicted tombstones authoritative.
Returned effects describe later Prolog/outcome work; this function performs no
I/O and exposes no prepared diff.
""".
-spec reduce(control(), certified_ref(), group_history(), projection()) ->
          {ok, group_history(), projection(), list()} | {error, term()}.
reduce(Control, Ref, History, Projection) ->
    case reduction_inputs(Control, Ref, History, Projection) of
        {ok, Kind, Record, GroupId, Digest, Records} ->
            case maps:find(Kind, Records) of
                {ok, #{digest := Digest}} ->
                    {ok, History, Projection, []};
                {ok, _Different} ->
                    {error, {invalid_transition, semantic_conflict}};
                error ->
                    reduce_new(
                      Kind, Record, GroupId, Digest, Ref,
                      History, Records, Projection)
            end;
        {error, _} = Error ->
            Error
    end.

reduction_inputs(Control, Ref, History, Projection) ->
    case {valid_control_shallow(Control), validate_certified_ref(Ref),
          valid_group_history(History), valid_projection(Projection)} of
        {true, true, true, true} ->
            Target = control_target(Control),
            Record = control_body(Control),
            Kind = control_kind(Control),
            Digest = record_digest(Control),
            GroupId =
                case Kind of
                    'begin' -> Digest;
                    _ -> record_group_id(Record)
                end,
            case {maps:get(target, Projection) =:= Target,
                  ref_identity(Ref) =:= Target,
                  ref_record_digest(Ref) =:= Digest,
                  history_accepts_group(History, GroupId)} of
                {true, true, true, true} ->
                    {ok, Kind, Record, GroupId, Digest,
                     maps:get(records, History)};
                _ ->
                    {error, {invalid_transition, bad_binding}}
            end;
        _ ->
            {error, {invalid_transition, malformed_state}}
    end.

reduce_new('begin', Record, GroupId, Digest, Ref,
           History, Records, Projection) ->
    case map_size(Records) =:= 0 andalso
         maps:get(active, Projection) =:= none andalso
         maps:get(consensus_lock, Projection) =:= open andalso
         metadata_fence_allowed(maps:get(proof_fence, Projection)) of
        true ->
            begin_transition(
              Record, GroupId, Digest, Ref, History, Projection);
        false ->
            {error, {invalid_transition, active_group}}
    end;
reduce_new(prepare, Record, GroupId, Digest, Ref,
           History, Records, Projection) ->
    case maps:get(generation, Projection) =< ?MAX_UINT64 - 2 andalso
         prepare_transition_allowed(Record, GroupId, Records, Projection) of
        {ok, Active0} ->
            {quod_dtx_prepare, ?RECORD_VERSION, _, BeginRef,
             Manifest, PlanDigest, PlanBlob} = Record,
            Generation = maps:get(generation, Projection) + 1,
            Participant =
                #{phase => prepared, begin_ref => BeginRef,
                  prepare_ref => Ref, plan_digest => PlanDigest,
                  manifest => Manifest, plan => PlanBlob},
            Active = Active0#{participant := Participant},
            Projection1 =
                Projection#{active := Active,
                            consensus_lock := {locked, GroupId},
                            proof_fence := {pending, GroupId},
                            generation := Generation},
            finish_reduction(
              prepare, Record, GroupId, Digest, Ref, History, Projection1,
              [{prepared, GroupId, Ref, Manifest, PlanDigest, PlanBlob,
                 Generation}]);
        {error, _} = Error ->
            Error;
        false ->
            {error, {invalid_transition, generation_exhausted}}
    end;
reduce_new(decision, Record, GroupId, Digest, Ref,
           History, Records, Projection) ->
    case maps:is_key('begin', Records) andalso
         decision_transition(Record, GroupId, Ref, Projection) of
        {ok, Verdict, Active} ->
            finish_reduction(
              decision, Record, GroupId, Digest, Ref, History,
              Projection#{active := Active},
              [{decided, GroupId, Verdict, Ref}]);
        {error, _} = Error -> Error;
        false -> {error, {invalid_transition, origin_phase}}
    end;
reduce_new(finalize, Record, GroupId, Digest, Ref,
           History, Records, Projection) ->
    case finalize_transition(Record, GroupId, Ref, Records, Projection) of
        {ok, Projection1, Effects} ->
            finish_reduction(
              finalize, Record, GroupId, Digest, Ref, History,
              Projection1, Effects);
        {error, _} = Error ->
            Error
    end;
reduce_new(complete, Record, GroupId, Digest, Ref,
           History, Records, Projection) ->
    case maps:is_key('begin', Records) andalso
         maps:is_key(decision, Records) andalso
         complete_transition(Record, GroupId, Records, Projection) of
        {ok, Verdict, ReasonsBlob, Projection1} ->
            finish_reduction(
              complete, Record, GroupId, Digest, Ref, History,
              Projection1,
              [completion_effect(
                 GroupId, Verdict, ReasonsBlob, Ref)]);
        {error, _} = Error -> Error;
        false -> {error, {invalid_transition, origin_phase}}
    end.

begin_transition(Record, GroupId, Digest, Ref, History, Projection) ->
    {quod_dtx_begin, ?RECORD_VERSION, Manifest, _} = Record,
    Origin =
        #{phase => begun, begin_ref => Ref,
          manifest_digest => manifest_digest_unchecked(Manifest),
          targets => participant_identities(Manifest)},
    Active =
        #{group_id => GroupId, origin => Origin, participant => none},
    finish_reduction(
      'begin', Record, GroupId, Digest, Ref, History,
      Projection#{active := Active}, [{origin_started, GroupId, Ref}]).

finish_reduction(Kind, Record, GroupId, Digest, Ref,
                 History, Projection, Effects) ->
    Records0 = maps:get(records, History),
    Entry = history_entry(Kind, Record, GroupId, Digest, Ref),
    History1 = History#{group_id := GroupId,
                        records := Records0#{Kind => Entry}},
    {ok, History1, Projection, Effects}.

history_entry(decision, Record, GroupId, Digest, Ref) ->
    #{group_id => GroupId, digest => Digest, ref => Ref, record => Record};
history_entry(_Kind, _Record, GroupId, Digest, Ref) ->
    #{group_id => GroupId, digest => Digest, ref => Ref}.

prepare_transition_allowed(
  {quod_dtx_prepare, ?RECORD_VERSION, GroupId, BeginRef, _, _, _},
  GroupId, Records, Projection) ->
    case {ref_record_digest(BeginRef) =:= GroupId,
          maps:is_key(finalize, Records), maps:is_key(complete, Records),
          maps:get(consensus_lock, Projection),
          maps:get(proof_fence, Projection), maps:get(active, Projection)} of
        {true, false, false, open, open, none} ->
            {ok, #{group_id => GroupId, origin => none, participant => none}};
        {true, false, false, open, open,
         #{group_id := GroupId, origin := Origin, participant := none} = Active}
          when Origin =/= none ->
            {ok, Active};
        {true, false, false, _, _, #{group_id := GroupId}} ->
            {error, {invalid_transition, participant_active}};
        {true, false, false, _, _, _} ->
            {error, {invalid_transition, active_group}};
        _ ->
            {error, {invalid_transition, phase_reversal}}
    end.

decision_transition(
  {quod_dtx_decision, ?RECORD_VERSION, GroupId, BeginRef, Verdict, Rows,
   _ReasonsBlob},
  GroupId, Ref,
  #{active :=
      #{group_id := GroupId,
        origin := #{phase := begun, begin_ref := BeginRef,
                    targets := Targets} = Origin} = Active}) ->
    case decision_rows_match(Verdict, Rows, Targets) of
        true ->
            Origin1 = Origin#{phase := {decided, Verdict}, decision_ref => Ref},
            {ok, Verdict, Active#{origin := Origin1}};
        false ->
            {error, {invalid_transition, bad_participant_set}}
    end;
decision_transition(_, _, _, _) ->
    {error, {invalid_transition, origin_phase}}.

decision_rows_match(commit, Rows, Targets) ->
    reference_row_identities(Rows) =:= Targets;
decision_rows_match(abort, Rows, Targets) ->
    ordered_subset(reference_row_identities(Rows), Targets).

finalize_transition(
  {quod_dtx_finalize, ?RECORD_VERSION, GroupId, DecisionRef, Verdict,
   SuppliedPrepareRef, AppliedGeneration}, GroupId, Ref,
  Records,
  #{active :=
      #{group_id := GroupId,
        participant :=
          #{phase := prepared, prepare_ref := StoredPrepareRef,
            manifest := Manifest, plan_digest := PlanDigest,
            plan := PlanBlob}} = Active,
    generation := Generation} = Projection) ->
    case finalize_prepare_matches(
           Verdict, SuppliedPrepareRef, StoredPrepareRef) andalso
         prepare_history_matches(Records, StoredPrepareRef) andalso
         expected_finalize_generation(Verdict, Generation) of
        {ok, AppliedGeneration} ->
            case decision_matches_active(Active, DecisionRef, Verdict) of
                true ->
            Active1 = release_participant(Active),
            Effect =
                case Verdict of
                    commit ->
                        {apply_prepared, GroupId, Manifest, PlanDigest,
                         PlanBlob, Ref, AppliedGeneration};
                    abort ->
                        {discard_prepared, GroupId, Manifest, PlanDigest,
                         PlanBlob, Ref, AppliedGeneration}
                end,
                    {ok,
                     Projection#{active := Active1, consensus_lock := open,
                                 proof_fence :=
                                   {pending_apply, GroupId, ref_slot(Ref),
                                    AppliedGeneration},
                                 generation := AppliedGeneration},
                     [Effect]};
                false ->
                    {error, {invalid_transition, origin_phase}}
            end;
        {ok, _OtherGeneration} ->
            {error, {invalid_transition, bad_applied_generation}};
        {error, _} = Error ->
            Error;
        false ->
            {error, {invalid_transition, participant_phase}}
    end;
finalize_transition(
  {quod_dtx_finalize, ?RECORD_VERSION, GroupId, DecisionRef, abort,
   none, AppliedGeneration}, GroupId, Ref,
  Records,
  #{generation := AppliedGeneration} = Projection) ->
    %% The certified direct abort is a metadata tombstone.  In particular it
    %% is allowed through another group's lock and changes no gate or role.
    case not maps:is_key(prepare, Records) andalso
         direct_decision_matches(Projection, GroupId, DecisionRef) of
        true ->
            {ok, Projection,
             [{direct_applied_abort, GroupId, Ref, AppliedGeneration}]};
        false ->
            {error, {invalid_transition, origin_phase}}
    end;
finalize_transition(
  {quod_dtx_finalize, ?RECORD_VERSION, _, _, commit, none, _}, _, _, _, _) ->
    {error, {invalid_transition, prepare_required}};
finalize_transition(_, _, _, _, _) ->
    {error, {invalid_transition, participant_phase}}.

complete_transition(
  {quod_dtx_complete, ?RECORD_VERSION, GroupId, DecisionRef, Rows}, GroupId,
  Records,
  #{active :=
      #{group_id := GroupId, participant := none,
        origin := #{phase := {decided, Verdict},
                    decision_ref := StoredDecision,
                    targets := Targets}},
    consensus_lock := open, proof_fence := Fence} = Projection) ->
    case {decision_history(Records, StoredDecision, GroupId, Verdict),
          StoredDecision =:= DecisionRef,
          finalize_row_identities(Rows) =:= Targets,
          metadata_fence_allowed(Fence)} of
        {{ok, ReasonsBlob}, true, true, true} ->
            {ok, Verdict, ReasonsBlob, Projection#{active := none}};
        _ -> {error, {invalid_transition, bad_completion_set}}
    end;
complete_transition(_, _, _, _) ->
    {error, {invalid_transition, origin_phase}}.

decision_history(Records, DecisionRef, GroupId, Verdict) ->
    case maps:find(decision, Records) of
        {ok, #{group_id := GroupId, ref := DecisionRef,
               record :=
                 {quod_dtx_decision, ?RECORD_VERSION, GroupId, _, Verdict,
                  _, ReasonsBlob} = Decision}} ->
            case ref_record_digest(DecisionRef) =:= record_digest(Decision) of
                true -> {ok, ReasonsBlob};
                false -> error
            end;
        _ ->
            error
    end.

completion_effect(GroupId, commit, none, Ref) ->
    {completed, GroupId, commit, Ref};
completion_effect(GroupId, abort, ReasonsBlob, Ref) ->
    {ok, Reasons} = decode_abort_reasons(ReasonsBlob),
    {completed, GroupId, abort, Ref, Reasons}.

-doc "Open the proof fence only for the exact prepared-Finalize acknowledgment.".
-spec acknowledge_finalize(<<_:256>>, pos_integer(), non_neg_integer(),
                           projection()) ->
          {ok, projection()} | {error, term()}.
acknowledge_finalize(GroupId, Slot, Generation,
                     #{proof_fence :=
                         {pending_apply, GroupId, Slot, Generation},
                       generation := Current} = Projection)
  when is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation =:= Current,
       Generation =< ?MAX_UINT64 ->
    case valid_projection(Projection) of
        true ->
            {ok, Projection#{proof_fence := open}};
        false ->
            {error, stale_finalize_ack}
    end;
acknowledge_finalize(_, _, _, _) ->
    {error, stale_finalize_ack}.

release_participant(#{origin := none}) -> none;
release_participant(Active) -> Active#{participant := none}.

decision_matches_active(
  #{origin := none,
    participant := #{begin_ref := BeginRef}}, DecisionRef, _Verdict) ->
    ref_identity(DecisionRef) =:= ref_identity(BeginRef);
decision_matches_active(
  #{origin := #{phase := {decided, Verdict}, decision_ref := DecisionRef}},
  DecisionRef, Verdict) -> true;
decision_matches_active(_, _, _) -> false.

direct_decision_matches(#{active := none}, _GroupId, _DecisionRef) -> true;
direct_decision_matches(
  #{active := #{group_id := GroupId,
                origin := #{phase := {decided, abort},
                            decision_ref := DecisionRef},
                participant := none}},
  GroupId, DecisionRef) -> true;
direct_decision_matches(
  #{active := #{group_id := ActiveGroup}}, GroupId, _DecisionRef)
  when ActiveGroup =/= GroupId -> true;
direct_decision_matches(_, _, _) -> false.

expected_finalize_generation(commit, ?MAX_UINT64) ->
    {error, {invalid_transition, generation_exhausted}};
expected_finalize_generation(commit, Generation) ->
    {ok, Generation + 1};
expected_finalize_generation(abort, Generation) ->
    {ok, Generation}.

prepare_history_matches(Records, PrepareRef) ->
    case maps:find(prepare, Records) of
        {ok, #{ref := StoredRef}} -> StoredRef =:= PrepareRef;
        error -> false
    end.

finalize_prepare_matches(commit, PrepareRef, PrepareRef) -> true;
finalize_prepare_matches(abort, PrepareRef, PrepareRef) -> true;
finalize_prepare_matches(_, _, _) -> false.

metadata_fence_allowed(open) -> true;
metadata_fence_allowed({pending_apply, _, _, _}) -> true;
metadata_fence_allowed(_) -> false.

participant_identities(Manifest) ->
    [Identity || {Identity, _} <- manifest_participants(Manifest)].

reference_row_identities(Rows) ->
    [Identity || {Identity, _} <- Rows].

finalize_row_identities(Rows) ->
    [Identity || {Identity, _, _} <- Rows].

ordered_subset([], _All) -> true;
ordered_subset(_, []) -> false;
ordered_subset([Identity | Rest], [Identity | AllRest]) ->
    ordered_subset(Rest, AllRest);
ordered_subset([Identity | _] = Wanted, [Candidate | AllRest])
  when Candidate < Identity ->
    ordered_subset(Wanted, AllRest);
ordered_subset(_, _) -> false.

valid_group_history(#{group_id := none, records := Records} = History)
  when map_size(History) =:= 2, is_map(Records) ->
    map_size(Records) =:= 0;
valid_group_history(#{group_id := <<_:256>> = GroupId,
                      records := Records} = History)
  when map_size(History) =:= 2, is_map(Records),
       map_size(Records) >= 1, map_size(Records) =< 5 ->
    valid_history_records(GroupId, maps:to_list(Records));
valid_group_history(_) -> false.

valid_history_records(_GroupId, []) -> true;
valid_history_records(
  GroupId,
  [{decision, #{group_id := GroupId, digest := <<_:256>> = Digest,
                ref := Ref,
                record :=
                  {quod_dtx_decision, ?RECORD_VERSION, GroupId, _, _, _, _} =
                    Record} = Entry} | Rest])
  when map_size(Entry) =:= 4 ->
    validate_certified_ref(Ref) andalso
        ref_record_digest(Ref) =:= Digest andalso
        valid_record(decision, Record) andalso
        record_digest(Record) =:= Digest andalso
        valid_history_records(GroupId, Rest);
valid_history_records(
  GroupId,
  [{Kind, #{group_id := GroupId, digest := <<_:256>> = Digest,
            ref := Ref} = Entry} | Rest])
  when map_size(Entry) =:= 3 ->
    Kind =/= decision andalso valid_kind(Kind) andalso
        validate_certified_ref(Ref) andalso
        ref_record_digest(Ref) =:= Digest andalso
        valid_history_records(GroupId, Rest);
valid_history_records(_, _) -> false.

valid_projection(
  #{target := Target, active := Active, consensus_lock := Lock,
    proof_fence := Fence, generation := Generation} = Projection)
  when map_size(Projection) =:= 5,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    valid_identity(Target) andalso valid_active(Active, Target) andalso
        valid_lock(Lock) andalso valid_fence(Fence) andalso
        gates_match_active(Active, Lock, Fence);
valid_projection(_) -> false.

valid_active(none, _Target) -> true;
valid_active(#{group_id := <<_:256>> = GroupId, origin := Origin,
               participant := Participant} = Active, Target)
  when map_size(Active) =:= 3 ->
    valid_origin_role(Origin) andalso
        valid_participant_role(Participant, Target, GroupId) andalso
        (Origin =/= none orelse Participant =/= none);
valid_active(_, _) -> false.

valid_origin_role(none) -> true;
valid_origin_role(#{phase := begun, begin_ref := Ref,
                    manifest_digest := <<_:256>>, targets := Targets} = Origin)
  when map_size(Origin) =:= 4 ->
    validate_certified_ref(Ref) andalso valid_identity_list(Targets);
valid_origin_role(#{phase := {decided, Verdict}, begin_ref := BeginRef,
                    manifest_digest := <<_:256>>, targets := Targets,
                    decision_ref := DecisionRef} = Origin)
  when map_size(Origin) =:= 5 ->
    valid_verdict(Verdict) andalso validate_certified_ref(BeginRef) andalso
        validate_certified_ref(DecisionRef) andalso
        valid_identity_list(Targets);
valid_origin_role(_) -> false.

valid_participant_role(none, _Target, _GroupId) -> true;
valid_participant_role(#{phase := prepared, begin_ref := BeginRef,
                         prepare_ref := PrepareRef,
                         plan_digest := <<_:256>> = PlanDigest,
                         manifest := Manifest,
                         plan := PlanBlob} = Participant, Target, GroupId)
  when map_size(Participant) =:= 6, is_binary(PlanBlob),
       byte_size(PlanBlob) =< ?QUOD_MAX_PLAN_ENVELOPE_BYTES ->
    validate_certified_ref(BeginRef) andalso
        validate_certified_ref(PrepareRef) andalso
        ref_identity(PrepareRef) =:= Target andalso
        valid_manifest(Manifest) andalso
        participant_plan_valid(
          Target, GroupId, BeginRef, PrepareRef,
          Manifest, PlanDigest, PlanBlob);
valid_participant_role(_, _, _) -> false.

participant_plan_valid(Target, GroupId, BeginRef, PrepareRef,
                       Manifest, PlanDigest, PlanBlob) ->
    Prepare = {quod_dtx_prepare, ?RECORD_VERSION, GroupId, BeginRef,
               Manifest, PlanDigest, PlanBlob},
    valid_prepare_record(
      Target, Prepare, GroupId, BeginRef, Manifest, PlanDigest, PlanBlob)
        andalso record_digest_unchecked(prepare, Prepare) =:=
            ref_record_digest(PrepareRef).

valid_identity_list(Identities) ->
    case bounded_length(Identities, ?QUOD_MAX_DTX_PARTICIPANTS) of
        {ok, Length} when Length >= 2 ->
            valid_identity_list(Identities, none);
        _ -> false
    end.

valid_identity_list([], _) -> true;
valid_identity_list([Identity | Rest], Previous)
  when Previous =:= none; Previous < Identity ->
    valid_identity(Identity) andalso valid_identity_list(Rest, Identity);
valid_identity_list(_, _) -> false.

valid_lock(open) -> true;
valid_lock({locked, <<_:256>>}) -> true;
valid_lock(_) -> false.

valid_fence(open) -> true;
valid_fence({pending, <<_:256>>}) -> true;
valid_fence({pending_apply, <<_:256>>, Slot, Generation})
  when is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 -> true;
valid_fence(_) -> false.

gates_match_active(
  #{group_id := GroupId, participant := #{phase := prepared}},
  {locked, GroupId}, {pending, GroupId}) -> true;
gates_match_active(#{participant := none}, open, open) -> true;
gates_match_active(
  #{participant := none}, open, {pending_apply, _, _, _}) -> true;
gates_match_active(none, open, open) -> true;
gates_match_active(none, open, {pending_apply, _, _, _}) -> true;
gates_match_active(_, _, _) -> false.

history_accepts_group(#{group_id := none}, _GroupId) -> true;
history_accepts_group(#{group_id := GroupId}, GroupId) -> true;
history_accepts_group(_, _) -> false.

record_group_id({quod_dtx_begin, ?RECORD_VERSION, _, _} = Begin) ->
    group_id(Begin);
record_group_id({quod_dtx_prepare, ?RECORD_VERSION, GroupId, _, _, _, _}) ->
    GroupId;
record_group_id({quod_dtx_decision, ?RECORD_VERSION, GroupId, _, _, _, _}) ->
    GroupId;
record_group_id({quod_dtx_finalize, ?RECORD_VERSION, GroupId, _, _, _, _}) ->
    GroupId;
record_group_id({quod_dtx_complete, ?RECORD_VERSION, GroupId, _, _}) ->
    GroupId.

ref_identity({quod_dtx_ref, ?REF_VERSION, Ns, Anchor, _, _, _, _}) ->
    {Ns, Anchor}.

ref_slot({quod_dtx_ref, ?REF_VERSION, _, _, Slot, _, _, _}) -> Slot.

ref_record_digest(
  {quod_dtx_ref, ?REF_VERSION, _, _, _, _, RecordDigest, _}) ->
    RecordDigest.

bounded_length(List, Max) ->
    bounded_length(List, Max, 0).

bounded_length([], _Max, Length) -> {ok, Length};
bounded_length([_ | Rest], Max, Length) when Length < Max ->
    bounded_length(Rest, Max, Length + 1);
bounded_length([_ | _], _Max, _Length) -> too_many;
bounded_length(_, _Max, _Length) -> improper.

bounded_proper_list(List, Max) ->
    case bounded_length(List, Max) of
        {ok, _} -> true;
        _ -> false
    end.
