-module(quod_atomic).
-moduledoc """
Canonical atomic group intent and the Vote/Resolve/Complete record family.

This pure library owns no process, timer, store, signing lane or transport.
Shared plan, manifest, attestation and ledger-reference codecs remain in
`m:quod_dtx`; the existing coordinator executes the atomic planner's work.

A group carries the deadline-bound manifest, request authentication and the
origin's compact plan attestation. Each Vote carries at most that role's own
bundle. A manifest presentation grants no prepared vote or outcome authority.
Resolve references exact ledger votes; neither an endpoint refusal, timeout,
nor an observed absence can authorize it. Complete retains the full role vector
and the required portable application certificates, after application.

Record decoding authenticates the contained request and plan material. Foreign
reference finality, role admission, OCC, certified block time and the installed
projection remain separate consensus-validation obligations, not constructor
claims. An expired signed request can still be authenticated for refusal and
cleanup; only a positive vote consumes the request's admission allowance.
""".

-include("quod_proof_limits.hrl").
-include("quod_ledger.hrl").

-export([requires_source_role/2, new_group/3, group_id/1, group_binding/1, source_group_ref/1,
         encode_group/1, decode_group/1, decode_presentation/3, source_presentation/1, encoded_record_digest/1,
         new_vote/4, new_resolve/7, new_complete/4,
         encode_record/1, decode_material/1, record_kind/1, record_target/1,
         record_digest/1, admission_material/1, select_vote/2,
         sign_control/6, encode_control/1, decode_control/1, verify_control/2,
         control_body/1, control_material/1, control_kind/1, control_target/1,
         control_metadata/1, control_order_key/1, canonical_control_wave/1,
         reference_requirements/1, encoded_reference_requirements/1, validate_references/2, intent_id/1,
         requires_network_identity/1, validate_request/4,
         initial_projection/2, valid_projection/1, proposal_readiness/2,
         reservation_readiness/2, content_readiness/2,
         initial_group_history/0, valid_group_history/1, history_phase/2,
         reduce/4, reduce_batch/3, preview_batch/3,
         acknowledge_resolve/4, install_projection/3, recovery_rows/2]).
-export_type([group/0, record/0, admission_material/0, control/0,
              projection/0, group_history/0]).

-define(VERSION, 4).
-define(CONTROL_VERSION, 3).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

-doc "Ordinary multiwriter proofs require an atomic source vote, even when the source has no writes.".
-spec requires_source_role(non_neg_integer(), boolean()) -> boolean().
requires_source_role(WriterCount, Independent) -> WriterCount >= 2 andalso not Independent.

-type identity() :: quod_proof_context:identity().
-type certified_reference() :: quod_dtx:certified_ref().
-type bundle() :: {identity(), <<_:256>>, binary(), quod_dtx:attestation()}.
-type outcome() :: commit | abort.
-type outcome_evidence() :: {all_prepared, [{identity(), certified_reference()}]} |
                            {refused, certified_reference()}.
-type group() :: {quod_atomic_group, 4, quod_dtx:manifest(),
                  none | quod_client_goal:request_auth(), quod_dtx:attestation()}.
-type record() ::
    {quod_dtx_vote, 4, group(), identity(), none | bundle(),
     prepared | {refused, binary()}} |
    {quod_dtx_resolve, 4, <<_:256>>, identity(), <<_:256>>, outcome(), certified_reference(),
     outcome_evidence(), none | certified_reference(), non_neg_integer(), none | binary()} |
    {quod_dtx_complete, 4, <<_:256>>, identity(), <<_:256>>, outcome(),
     [{identity(), certified_reference(), non_neg_integer()}],
     [{identity(), quod_applied_certificate:applied_certificate()}]}.
%% Shared immutable validation data, read by the validator, reducer and journal.
%% Authentication belongs to the constructors; this is not an ownership token.
-type admission_material() :: {record(), <<_:256>>, map()}.
%% Only the codec/signing constructors create this process-local envelope.
%% Its material is authenticated once; the wire contains record BYTES instead.
-opaque control() :: {quod_dtx_control, 3, vote | resolve | complete,
                      identity(), admission_material(), <<_:256>>, <<_:256>>,
                      pos_integer(), non_neg_integer(), <<_:512>>}.
-type projection() :: #{target := identity(), groups := map(),
                          apply_fences := map(), generation := non_neg_integer()}.
-type group_history() :: #{group_id := none | <<_:256>>, records := map()}.

-doc "Bind the shared manifest to its signed request and existing origin attestation.".
-spec new_group(quod_dtx:manifest(), none | quod_client_goal:request_auth(),
                quod_dtx:attestation()) -> {ok, group()} | {error, invalid_group}.
new_group(Manifest, RequestAuth, OriginAttestation) ->
    Group = {quod_atomic_group, ?VERSION, Manifest, RequestAuth, OriginAttestation},
    case group_binding(Group) of
        {ok, _} -> {ok, Group};
        error -> {error, invalid_group}
    end.

-doc "Authenticate a group's source witness and request; no origin vote is implied.".
-spec group_binding(group()) -> {ok, map()} | error.
group_binding({quod_atomic_group, ?VERSION, Manifest, RequestAuth, Attestation} = Group) ->
    case bind_group(Group, Manifest, RequestAuth, Attestation, none) of
        {ok, #{group := Binding}} -> {ok, Binding};
        error -> error
    end;
group_binding(_) -> error.

-doc "Encode an already-owned compact group for exact recovery presentation.".
-spec encode_group(group()) -> binary().
encode_group(Group = {quod_atomic_group, ?VERSION, _, _, _}) -> bytes(Group).

-doc "Authenticate a bounded canonical presentation, returning its checked group binding once.".
-spec decode_group(binary()) -> {ok, map()} | error.
decode_group(Blob) ->
    case canonical_body(Blob) of
        {ok, Group} -> group_binding(Group);
        error -> error
    end.

-doc "Authenticate a compact O-only presentation once; its missing-material vote still needs parent/deadline validation.".
-spec decode_presentation(identity(), <<_:256>>, binary()) -> {ok, admission_material()} | error.
decode_presentation(Origin, Id, Blob) ->
    case decode_group(Blob) of
        {ok, #{origin := Origin, group_id := Id} = Binding} ->
            {Record, _, _} = Material = presentation(Binding),
            case within_limit(Record) of true -> {ok, Material}; false -> error end;
        _ -> error
    end.

-doc "Derive O's missing-material admission from authenticated custody; it grants no vote before the deadline.".
-spec source_presentation(admission_material()) -> admission_material().
source_presentation({_, _, #{group := Binding}}) -> presentation(Binding).

presentation(#{origin := Origin, group := Group} = Binding) ->
    {ok, Reasons} = quod_wire_term:encode_failure_reasons([vote_deadline]),
    Record = {quod_dtx_vote, ?VERSION, Group, Origin, none, {refused, Reasons}},
    {Record, record_digest(Record), #{group => Binding, plans => #{},
                                    intent_id => vote_intent(Group, Origin, none)}}.

bind_group(Group, Manifest, RequestAuth, Attestation, Bundle) ->
    case within_limit(Group) andalso
         quod_dtx:attested_group_material(Manifest, Attestation, Bundle) of
        {ok, #{group := #{participants := Roles, vote_deadline_ms := Deadline} = Binding} = Material}
          when length(Roles) >= 2, is_integer(Deadline) ->
            case request_binding(RequestAuth, Binding) of
                {ok, Evidence} ->
                    {ok, Material#{group := Binding#{group => Group, manifest => Manifest,
                                  group_id => group_digest(maps:get(manifest_digest, Binding)),
                                  request => Evidence}}};
                error -> error
            end;
        _ -> error
    end.

request_binding(none, #{request_binding := none}) -> {ok, none};
request_binding(Auth, #{goal := Goal, origin := Origin, principal := Principal,
                        request_binding := RequestBinding, vote_deadline_ms := Deadline}) ->
    case quod_client_goal:verify_durable_request(Auth, Goal) of
        {ok, #{evidence := Evidence, principal := Principal,
               claim := #{target := Origin, deadline := Expiry}} = Verified} ->
            case Deadline =< Expiry andalso
                 quod_client_goal:request_binding(Evidence) =:= RequestBinding of
                true -> {ok, Verified};
                false -> error
            end;
        _ -> error
    end.

-doc "The domain-separated manifest identity, unchanged by votes or proof subsets.".
-spec group_id(group() | record() | control()) -> <<_:256>>.
group_id({quod_dtx_control, ?CONTROL_VERSION, _, _, {Record, _, _}, _, _, _, _, _}) ->
    group_id(Record);
group_id({quod_atomic_group, ?VERSION, Manifest, _, _}) ->
    group_digest(quod_dtx:manifest_digest(Manifest));
group_id({quod_dtx_vote, ?VERSION, Group, _, _, _}) -> group_id(Group);
group_id({quod_dtx_resolve, ?VERSION, GroupId, _, _, _, _, _, _, _, _}) -> GroupId;
group_id({quod_dtx_complete, ?VERSION, GroupId, _, _, _, _, _}) -> GroupId.

group_digest(ManifestDigest) -> digest({<<"quod.dtx.group">>, ?VERSION, ManifestDigest}).

-doc "The public source reference from its already-authenticated own Vote; other roles cannot register source custody.".
-spec source_group_ref(admission_material()) -> {ok, tuple()} | error.
source_group_ref({{quod_dtx_vote, ?VERSION, _, Target, _, _}, _,
                   #{group := #{origin := Target, manifest := Manifest, group_id := Id}}}) ->
    quod_dtx:manifest_group_ref(Manifest, Id);
source_group_ref(_) -> error.

-doc "Construct one role's exclusive vote, retaining only its own material.".
-spec new_vote(group(), identity(), none | bundle(),
               prepared | {refused, nonempty_list(term())}) ->
          {ok, record()} | {error, invalid_record}.
new_vote(Group, Target, OwnBundle, prepared) ->
    new_record({quod_dtx_vote, ?VERSION, Group, Target, OwnBundle, prepared});
new_vote(Group, Target, OwnBundle, {refused, [_ | _] = Reasons}) ->
    case quod_wire_term:encode_failure_reasons(Reasons) of
        {ok, Blob} ->
            new_record({quod_dtx_vote, ?VERSION, Group, Target, OwnBundle, {refused, Blob}});
        _ -> {error, invalid_record}
    end;
new_vote(_, _, _, _) -> {error, invalid_record}.

-doc "Bind resolution to the source's enrollment vote and exact outcome evidence.".
-spec new_resolve(group(), certified_reference(), identity(), commit | {abort, nonempty_list()}, outcome_evidence(),
                  none | certified_reference(), non_neg_integer()) ->
          {ok, record()} | {error, invalid_record}.
new_resolve(Group, OriginVote, Target, Result, Evidence, OwnVote, Generation) ->
    case {group_binding(Group), resolution_result(Result)} of
        {{ok, #{group_id := GroupId, manifest_digest := ManifestDigest,
                origin := Origin, participants := Roles}}, {ok, Outcome, Reasons}} ->
            case reference_target(OriginVote, Origin) andalso lists:keymember(Target, 1, Roles) of
                true -> new_record({quod_dtx_resolve, ?VERSION, GroupId, Target,
                                    ManifestDigest, Outcome, OriginVote, Evidence, OwnVote, Generation, Reasons});
                false -> {error, invalid_record}
            end;
        _ -> {error, invalid_record}
    end.

resolution_result(commit) -> {ok, commit, none};
resolution_result({abort, [_ | _] = Reasons}) ->
    case quod_wire_term:encode_failure_reasons(Reasons) of
        {ok, Blob} -> {ok, abort, Blob};
        _ -> error
    end;
resolution_result(_) -> error.

resolution_reasons(commit, none) -> {ok, none};
resolution_reasons(abort, Blob) when is_binary(Blob) -> quod_wire_term:decode_failure_reasons(Blob);
resolution_reasons(_, _) -> error.

-doc "Build the source's complete role/application vector; readiness is validated separately.".
-spec new_complete(group(), outcome(), list(), list()) ->
          {ok, record()} | {error, invalid_record}.
new_complete(Group, Outcome, Rows, Applied) ->
    case group_binding(Group) of
        {ok, #{group_id := GroupId, origin := Origin,
               manifest_digest := ManifestDigest, participants := Roles}} ->
            case reference_rows(Rows, generation) andalso
                 [Target || {Target, _, _} <- Rows] =:= [Target || {Target, _} <- Roles] of
                true -> new_record({quod_dtx_complete, ?VERSION, GroupId, Origin,
                                    ManifestDigest, Outcome, Rows, Applied});
                false -> {error, invalid_record}
            end;
        error -> {error, invalid_record}
    end.

new_record(Record) ->
    case admission_material(Record) of
        {ok, _} -> {ok, Record};
        error -> {error, invalid_record}
    end.

-doc "Encode the single current atomic record family; no legacy arm.".
-spec encode_record(record()) -> {ok, binary()} | {error, invalid_record}.
encode_record(Record) ->
    case admission_material(Record) of
        {ok, _} -> {ok, bytes(Record)};
        error -> {error, invalid_record}
    end.

-doc "Decode bounded canonical bytes, retaining authenticated own material for all later transitions.".
-spec decode_material(binary()) -> {ok, admission_material()} | error.
decode_material(Blob) ->
    case canonical_body(Blob) of
        {ok, Record} -> admission_material(Record);
        error -> error
    end.

canonical_body(Blob) when is_binary(Blob), byte_size(Blob) =< ?QUOD_MAX_DTX_BODY_BYTES ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, Term} ->
            case bytes(Term) =:= Blob of
                true -> {ok, Term};
                false -> error
            end;
        _ -> error
    end;
canonical_body(_) -> error.

-doc "Hash canonical record bytes for transport correlation only; this grants no admission authority.".
-spec encoded_record_digest(binary()) -> {ok, <<_:256>>} | error.
encoded_record_digest(Blob) ->
    case canonical_body(Blob) of
        {ok, Record} ->
            case record_kind(Record) of
                invalid -> error;
                _ -> {ok, record_digest(Record)}
            end;
        error -> error
    end.

-doc "Classify only the current Vote, Resolve and Complete shapes.".
-spec record_kind(term()) -> vote | resolve | complete | invalid.
record_kind({quod_dtx_vote, ?VERSION, _, _, _, _}) -> vote;
record_kind({quod_dtx_resolve, ?VERSION, _, _, _, _, _, _, _, _, _}) -> resolve;
record_kind({quod_dtx_complete, ?VERSION, _, _, _, _, _, _}) -> complete;
record_kind(_) -> invalid.

-doc "Hash semantic record bytes; callers establish authentication independently.".
-spec record_digest(record() | control()) -> <<_:256>>.
record_digest({quod_dtx_control, ?CONTROL_VERSION, _, _, {_, Digest, _}, _, _, _, _, _}) ->
    Digest;
record_digest(Record) ->
    Kind = record_kind(Record),
    true = Kind =/= invalid,
    digest({<<"quod.dtx.record">>, ?VERSION, Kind, Record}).

-doc "Authenticate once at an admission boundary and carry its exact material forward.".
-spec admission_material(record()) -> {ok, admission_material()} | error.
admission_material(Record) ->
    case within_limit(Record) of
        true ->
            case record_material(Record) of
                {ok, Material} -> {ok, {Record, record_digest(Record), Material}};
                error -> error
            end;
        false -> error
    end.

-doc "Sign owned admission material without re-authenticating plans; no raw record or wire input is accepted.".
-spec sign_control(identity(), admission_material(), <<_:256>>, pos_integer(), non_neg_integer(),
                   quod_identity:signer()) -> {ok, control()} | {error, invalid_control}.
sign_control(Target, Material = {Record, <<_:256>>, Meta}, <<_:256>> = Admission, Sequence, SubmittedAt,
             #{pubkey := <<_:256>> = Author} = Signer) ->
    case is_map(Meta) andalso uint(Sequence) andalso Sequence > 0 andalso uint(SubmittedAt)
         andalso record_kind(Record) =/= invalid andalso record_target(Record) =:= Target of
        true ->
            Control = {quod_dtx_control, ?CONTROL_VERSION, record_kind(Record),
                       Target, Material, Author, Admission, Sequence, SubmittedAt, <<0:512>>},
            Signature = quod_identity:sign(control_bytes(Control), Signer),
            Signed = setelement(10, Control, Signature),
            case encode_control(Signed) of
                {ok, _} -> {ok, Signed};
                _ -> {error, invalid_control}
            end;
        _ -> {error, invalid_control}
    end;
sign_control(_, _, _, _, _, _) -> {error, invalid_control}.

-doc "Serialize an opaque local control without exporting its cached material.".
-spec encode_control(control()) -> {ok, binary()} | {error, invalid_control}.
encode_control({quod_dtx_control, ?CONTROL_VERSION, Kind, Target, {Record, _, _},
                <<_:256>> = Author, <<_:256>> = Admission, Sequence, SubmittedAt,
                <<_:512>> = Signature}) ->
    case valid_identity(Target) andalso uint(Sequence) andalso Sequence > 0
         andalso uint(SubmittedAt) andalso record_kind(Record) =:= Kind
         andalso record_target(Record) =:= Target of
        true ->
            Blob = bytes({quod_dtx_control, ?CONTROL_VERSION, Kind, Target, bytes(Record),
                          Author, Admission, Sequence, SubmittedAt, Signature}),
            case byte_size(Blob) =< ?QUOD_MAX_DTX_CONTROL_BYTES of
                true -> {ok, Blob};
                false -> {error, invalid_control}
            end;
        false -> {error, invalid_control}
    end;
encode_control(_) -> {error, invalid_control}.

-doc "Decode canonical control bytes and authenticate embedded plans once; verify author separately.".
-spec decode_control(binary()) -> {ok, control()} | {error, invalid_control}.
decode_control(Blob) when is_binary(Blob), byte_size(Blob) =< ?QUOD_MAX_DTX_CONTROL_BYTES ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_DTX_CONTROL_BYTES) of
        {ok, {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, RecordBlob,
              <<_:256>> = Author, <<_:256>> = Admission, Sequence, SubmittedAt,
              <<_:512>> = Signature} = Wire} when is_binary(RecordBlob) ->
            case valid_identity(Target) andalso valid_kind(Kind) andalso uint(Sequence)
                 andalso Sequence > 0 andalso uint(SubmittedAt) andalso bytes(Wire) =:= Blob
                 andalso decode_material(RecordBlob) of
                {ok, {Record, _, _} = Material} ->
                    case record_kind(Record) =:= Kind andalso record_target(Record) =:= Target of
                        true -> {ok, {quod_dtx_control, ?CONTROL_VERSION, Kind, Target, Material,
                                      Author, Admission, Sequence, SubmittedAt, Signature}};
                        false -> {error, invalid_control}
                    end;
                _ -> {error, invalid_control}
            end;
        _ -> {error, invalid_control}
    end;
decode_control(_) -> {error, invalid_control}.

-doc "Verify the exact author/target binding of a codec-created control, without rechecking its plans.".
-spec verify_control(identity(), control()) -> boolean().
verify_control(Expected, {quod_dtx_control, ?CONTROL_VERSION, _, Expected, _,
                         Author, _, _, _, Signature} = Control) ->
    quod_identity:verify(Signature, control_bytes(Control), Author);
verify_control(_, _) -> false.

control_bytes({quod_dtx_control, ?CONTROL_VERSION, Kind, Target, {Record, _, _},
               Author, Admission, Sequence, SubmittedAt, _}) ->
    bytes({<<"quod.dtx.control">>, ?CONTROL_VERSION, Kind, Target, bytes(Record),
           Author, Admission, Sequence, SubmittedAt}).

-doc "Read the semantic body from a codec-created control.".
-spec control_body(control()) -> record().
control_body(Control) -> {Record, _, _} = control_material(Control), Record.
-doc "Carry the exact authenticated material into owner classification or ledger reduction.".
-spec control_material(control()) -> admission_material().
control_material({quod_dtx_control, ?CONTROL_VERSION, _, _, Material, _, _, _, _, _}) -> Material.
-doc "Read the atomic phase of a codec-created control.".
-spec control_kind(control()) -> vote | resolve | complete.
control_kind({quod_dtx_control, ?CONTROL_VERSION, Kind, _, _, _, _, _, _, _}) -> Kind.
-doc "Read the anchored role that owns this control's signing lane.".
-spec control_target(control()) -> identity().
control_target({quod_dtx_control, ?CONTROL_VERSION, _, Target, _, _, _, _, _, _}) -> Target.
-doc "Read journal authorship without interpreting the record or its plans.".
-spec control_metadata(control()) -> map().
control_metadata({quod_dtx_control, ?CONTROL_VERSION, Kind, Target, _, Author, Admission,
                  Sequence, SubmittedAt, _}) ->
    #{kind => Kind, target => Target, author => Author, author_admission => Admission,
      sequence => Sequence, submitted_at => SubmittedAt}.
-doc "The existing signing-lane sequence order, with semantic group and target tie-breaks.".
-spec control_order_key(control()) -> tuple().
control_order_key(Control) ->
    #{author := Author, author_admission := Admission, sequence := Seq} = control_metadata(Control),
    {{Admission, Author}, Seq, group_id(Control), control_target(Control)}.

-doc "Whether a decoded vote needs the network identity; later phases carry exact vote evidence.".
-spec requires_network_identity(admission_material()) -> boolean().
requires_network_identity(Material) ->
    case Material of
        {{quod_dtx_vote, ?VERSION, _, _, _, _}, _, #{group := #{request := Request}}} ->
            Request =/= none;
        _ -> false
    end.

-doc """
Check the source-bound request and vote deadline at the certified block time.

Decode already authenticated request, principal, source identity and manifest
bindings. A target checks that SAME origin request, not a request addressed
to itself. No signature, goal parsing or wall-clock read is repeated here.
After the bound deadline only a negative vote is eligible, including after a
signed request expires: expiry cannot prevent the group's certified closure.
The separate own-plan policy/OCC check must justify any negative vote's cause.
""".
-spec validate_request(term(), identity(), non_neg_integer(), admission_material()) ->
          {ok, none | map()} | {error, invalid_request_binding | wrong_network | vote_deadline}.
validate_request(Network, Target, Timestamp, Material = {Record, _, _}) ->
    case record_target(Record) =:= Target andalso uint(Timestamp) of
        false -> {error, invalid_request_binding};
        true ->
            case Material of
                {{quod_dtx_vote, ?VERSION, _, Target, _, Choice}, _,
                 #{group := #{request := Request, vote_deadline_ms := Deadline}}} ->
                    case request_network(Request, Network) of
                        false -> {error, wrong_network};
                        true when Choice =:= prepared, Timestamp > Deadline -> {error, vote_deadline};
                        true -> {ok, Request}
                    end;
                _ -> {ok, none}
            end
    end.

request_network(none, _) -> true;
request_network(#{evidence := #{request := #{network_identity := Network}}}, Network) -> true;
request_network(_, _) -> false.

-doc """
Select an uncommitted vote over the same owned intent without reauthenticating it.

The owner must obtain Choice from committed-parent admission; this pure change
grants no voting authority. It cannot change a group, deadline, target, own
bundle or provenance. Journal publication still requires a fresh higher sequence,
and the reducer never replaces a committed vote. Missing material cannot prepare.
""".
-spec select_vote(admission_material(), prepared | {refused, nonempty_list()}) ->
          {ok, admission_material()} | error.
select_vote(Material = {{quod_dtx_vote, ?VERSION, _, _, Own, _} = Record, _, Meta}, Choice) ->
    Encoded = case Choice of
        prepared when Own =/= none -> {ok, prepared};
        {refused, [_ | _] = Reasons} ->
            case quod_wire_term:encode_failure_reasons(Reasons) of
                {ok, Blob} -> {ok, {refused, Blob}};
                _ -> error
            end;
        _ -> error
    end,
    case Encoded of
        {ok, Selected} ->
            Updated = setelement(6, Record, Selected),
            case {Updated =:= Record, within_limit(Updated)} of
                {true, true} -> {ok, Material};
                {false, true} -> {ok, {Updated, record_digest(Updated), Meta}};
                _ -> error
            end;
        error -> error
    end;
select_vote(_, _) -> error.

-doc "Validate one nonempty same-role/same-phase wave with strictly increasing lane sequences.".
-spec canonical_control_wave([control()]) -> boolean().
canonical_control_wave([{quod_dtx_control, ?CONTROL_VERSION, Kind, Target,
                         _, _, _, _, _, _} | _] = Controls) ->
    valid_kind(Kind) andalso valid_identity(Target) andalso wave(Controls, Target, Kind, none);
canonical_control_wave(_) -> false.
wave([], _, _, _) -> true;
wave([{quod_dtx_control, ?CONTROL_VERSION, Kind, Target,
       _, _, _, _, _, _} = Control | Rest], Target, Kind, Previous) ->
    {Lane, Seq, _, _} = control_order_key(Control),
    Key = {Lane, Seq},
    control_target(Control) =:= Target andalso control_kind(Control) =:= Kind
        andalso (Previous =:= none orelse Previous < Key)
        andalso wave(Rest, Target, Kind, Key);
wave(_, _, _, _) -> false.

valid_kind(vote) -> true;
valid_kind(resolve) -> true;
valid_kind(complete) -> true;
valid_kind(_) -> false.

-doc "The owning ontology of an already-authenticated atomic record.".
-spec record_target(record()) -> identity().
record_target({quod_dtx_vote, ?VERSION, _, Target, _, _}) -> Target;
record_target({quod_dtx_resolve, ?VERSION, _, Target, _, _, _, _, _, _, _}) -> Target;
record_target({quod_dtx_complete, ?VERSION, _, Origin, _, _, _, _}) -> Origin.

-doc "Return exact reference obligations from an owned control, record or decoded material; never reauthenticate it.".
-spec reference_requirements(control() | record() | admission_material()) -> [{vote | resolve, certified_reference()}].
reference_requirements({quod_dtx_control, ?CONTROL_VERSION, _, _, Material, _, _, _, _, _}) ->
    reference_requirements(Material);
reference_requirements({Record, <<_:256>>, _}) -> reference_requirements(Record);
reference_requirements(Record) ->
    %% Certificate subsets are interchangeable, not distinct obligations.
    Indexed = lists:foldl(fun({Kind, Ref}, Acc) ->
        Key = reference_key(Kind, Ref),
        case maps:is_key(Key, Acc) of true -> Acc; false -> Acc#{Key => {Kind, Ref}} end
    end, #{}, record_references(Record)),
    [Row || {_, Row} <- lists:sort(maps:to_list(Indexed))].

record_references({quod_dtx_vote, ?VERSION, _, _, _, _}) -> [];
record_references({quod_dtx_resolve, ?VERSION, _, _, _, _, OriginVote, Evidence, OwnVote, _, _}) ->
    [{vote, OriginVote} | outcome_ref_rows(Evidence)] ++
      case OwnVote of none -> []; _ -> [{vote, OwnVote}] end;
record_references({quod_dtx_complete, ?VERSION, _, _, _, _, Rows, _}) ->
    [{resolve, Ref} || {_, Ref, _} <- Rows].
outcome_ref_rows({all_prepared, Rows}) -> [{vote, Ref} || {_, Ref} <- Rows];
outcome_ref_rows({refused, Ref}) -> [{vote, Ref}].
reference_key(Kind, Ref) ->
    {ok, Claim} = quod_dtx:certified_ref_claim(Ref), {Kind, Claim}.

-doc """
Select optional exact-entry transport hints from bounded canonical bytes.
This grants no admission authority. Votes have no foreign references and need
no request/plan authentication here; Resolve/Complete reuse their structural
record check. The receiving owner's ordinary decoder authenticates admission.
""".
-spec encoded_reference_requirements(binary()) -> {ok, [{vote | resolve, certified_reference()}]} | error.
encoded_reference_requirements(Blob) ->
    case canonical_body(Blob) of
        {ok, {quod_dtx_vote, ?VERSION, _, _, _, _}} -> {ok, []};
        {ok, Record} ->
            case record_material(Record) of
                {ok, _} -> {ok, reference_requirements(Record)};
                error -> error
            end;
        error -> error
    end.

-doc """
Bind already-verified foreign evidence to the exact atomic record.

Each supplied material comes from its decoded control, whose author and
ledger finality have already been verified by the existing resolver. No
signature or plan decoding is repeated here. Applied certificate signatures
likewise remain the existing AM3 verifier's obligation; this seam checks their
exact statement bindings. Missing, surplus or substituted evidence is refused.
""".
-spec validate_references(control(),
                          [{vote | resolve, certified_reference(), admission_material()}]) ->
          ok | {error, invalid_references}.
validate_references(Control, Evidence) ->
    {Record, _, Meta} = Material = control_material(Control),
    case index_evidence(reference_requirements(Material), Evidence, #{}) of
        {ok, Index} ->
            case reference_chain(Record, Meta, Index) of
                {ok, _} -> ok;
                error -> {error, invalid_references}
            end;
        error -> {error, invalid_references}
    end.

index_evidence([], [], Index) -> {ok, Index};
index_evidence([{Kind, Required} | Rest], [{Kind, Ref, {Record, Digest, _} = Material} | Rows], Index) ->
    case quod_dtx:same_certified_ref(Required, Ref) andalso record_kind(Record) =:= Kind of
        true ->
            case quod_dtx:certified_ref_binding(Ref) of
                {ok, Target, _, Digest} ->
                    case record_target(Record) =:= Target of
                        true -> index_evidence(Rest, Rows, Index#{reference_key(Kind, Ref) => Material});
                        false -> error
                    end;
                _ -> error
            end;
        false -> error
    end;
index_evidence(_, _, _) -> error.

reference_chain({quod_dtx_vote, ?VERSION, _, _, _, _}, Meta, Index) when map_size(Index) =:= 0 ->
    {ok, Meta};
reference_chain({quod_dtx_resolve, ?VERSION, GroupId, Target, ManifestDigest, Outcome,
                 OriginVote, Evidence, OwnVote, _, _}, Meta = #{reasons := Reasons}, Index) ->
    {{quod_dtx_vote, ?VERSION, _, Voter, _, _}, _, #{group := Binding}} =
        maps:get(reference_key(vote, OriginVote), Index),
    #{origin := Origin, participants := Roles} = Binding,
    case Voter =:= Origin andalso maps:get(group_id, Binding) =:= GroupId
         andalso maps:get(manifest_digest, Binding) =:= ManifestDigest
         andalso lists:keymember(Target, 1, Roles)
         andalso same_source_vote(Target, Origin, OwnVote, OriginVote)
         andalso commit_vote_bindings(Outcome, Evidence, Origin, OriginVote, Target, OwnVote)
         andalso own_vote_matches(OwnVote, Target, GroupId, Index)
         andalso outcome_matches(Outcome, Evidence, Binding, Index) of
        {ok, Reasons} -> {ok, Meta};
        _ -> error
    end;
reference_chain({quod_dtx_complete, ?VERSION, GroupId, Origin, ManifestDigest, Outcome,
                 Rows, Applied}, Meta, Index) ->
    case complete_rows_match(Rows, GroupId, ManifestDigest, Outcome, Index) andalso
         complete_applied_match(Rows, Applied, GroupId, Origin, Outcome, Index) of
        true -> {ok, Meta};
        false -> error
    end.

same_source_vote(Origin, Origin, OwnVote, OriginVote) ->
    quod_dtx:same_certified_ref(OwnVote, OriginVote);
same_source_vote(_, _, _, _) -> true.
commit_vote_bindings(abort, _, _, _, _, _) -> true;
commit_vote_bindings(commit, {all_prepared, Rows}, Origin, OriginVote, Target, OwnVote) ->
    row_ref_matches(Origin, OriginVote, Rows) andalso row_ref_matches(Target, OwnVote, Rows).
row_ref_matches(Target, Ref, Rows) ->
    case lists:keyfind(Target, 1, Rows) of
        {Target, RowRef} -> quod_dtx:same_certified_ref(Ref, RowRef);
        false -> false
    end.

own_vote_matches(none, _, _, _) -> true;
own_vote_matches(Ref, Target, GroupId, Index) ->
    case maps:get(reference_key(vote, Ref), Index) of
        {{quod_dtx_vote, ?VERSION, _, Target, _, _}, _, #{group := #{group_id := GroupId}}} -> true;
        _ -> false
    end.

outcome_matches(commit, {all_prepared, Rows}, #{group_id := GroupId, participants := Roles}, Index) ->
    case [T || {T, _} <- Rows] =:= [T || {T, _} <- Roles] andalso
         lists:all(fun({T, Ref}) ->
             case maps:get(reference_key(vote, Ref), Index) of
                 {{quod_dtx_vote, ?VERSION, _, T, _, prepared}, _,
                  #{group := #{group_id := GroupId}}} -> true;
                 _ -> false
             end
         end, Rows) of
        true -> {ok, none};
        false -> error
    end;
outcome_matches(abort, {refused, Ref}, #{group_id := GroupId}, Index) ->
    case maps:get(reference_key(vote, Ref), Index) of
        {{quod_dtx_vote, ?VERSION, _, _, _, {refused, Reasons}}, _,
         #{group := #{group_id := GroupId}}} -> quod_wire_term:decode_failure_reasons(Reasons);
        _ -> error
    end;
outcome_matches(_, _, _, _) -> error.

same_request_key(#{request := #{claim := #{operation_ref := Key}}},
                 #{request := #{claim := #{operation_ref := Key}}}) -> true;
same_request_key(_, _) -> false.

complete_rows_match([], _, _, _, _) -> true;
complete_rows_match([{Target, Ref, Generation} | Rest], GroupId, ManifestDigest, Outcome, Index) ->
    case maps:get(reference_key(resolve, Ref), Index) of
        {{quod_dtx_resolve, ?VERSION, GroupId, Target, ManifestDigest, Outcome,
          _, _, _, Generation, _}, _, _} ->
            complete_rows_match(Rest, GroupId, ManifestDigest, Outcome, Index);
        _ -> false
    end.

complete_applied_match([], [], _, _, _, _) -> true;
complete_applied_match([{Origin, _, _} | Rest], Applied, GroupId, Origin, Outcome, Index) ->
    %% The source's existing owner-apply fence gates a live Complete proposal;
    %% its certified inclusion suffices on replay. No second local collector.
    complete_applied_match(Rest, Applied, GroupId, Origin, Outcome, Index);
complete_applied_match([{Target, Ref, Generation} | Rest], Applied, GroupId, Origin, Outcome, Index) ->
    {{quod_dtx_resolve, ?VERSION, _, _, _, _, _, _, OwnVote, _, _}, _, _} =
        maps:get(reference_key(resolve, Ref), Index),
    case {Outcome, OwnVote, Applied} of
        {abort, none, _} ->
            %% An unvoted role's certified tombstone applies no material.
            complete_applied_match(Rest, Applied, GroupId, Origin, Outcome, Index);
        {_, _, [{Target, Certificate} | Certificates]} ->
            case quod_applied_certificate:applied_certificate_binding(Certificate) of
                {ok, #{target := Target, group_id := GroupId, generation := Generation,
                       verdict := Outcome, resolve_ref := CertifiedRef}} ->
                    quod_dtx:same_certified_ref(Ref, CertifiedRef) andalso
                        complete_applied_match(Rest, Certificates, GroupId, Origin, Outcome, Index);
                _ -> false
            end;
        _ -> false
    end;
complete_applied_match(_, _, _, _, _, _) -> false.

record_material({quod_dtx_vote, ?VERSION,
                 {quod_atomic_group, ?VERSION, Manifest, RequestAuth, Attestation} = Group,
                 Target, Bundle, Choice}) ->
    case valid_choice(Choice) andalso own_bundle(Bundle, Target, Choice)
         andalso bind_group(Group, Manifest, RequestAuth, Attestation, Bundle) of
        {ok, #{group := #{participants := Roles}} = Material} ->
            case lists:keymember(Target, 1, Roles) of
                true -> {ok, Material#{intent_id => vote_intent(Group, Target, Bundle)}};
                false -> error
            end;
        _ -> error
    end;
record_material({quod_dtx_resolve, ?VERSION, GroupId, Target, ManifestDigest,
                 Outcome, OriginVote, Evidence, OwnVote, Generation, ReasonsBlob}) ->
    case group_matches(GroupId, ManifestDigest) andalso valid_identity(Target)
         andalso uint(Generation) andalso valid_outcome(Outcome)
         andalso quod_dtx:validate_certified_ref(OriginVote)
         andalso outcome_references(Outcome, Evidence)
         andalso ((OwnVote =:= none andalso Outcome =:= abort) orelse
                  reference_target(OwnVote, Target))
         andalso resolution_reasons(Outcome, ReasonsBlob) of
        {ok, Reasons} -> {ok, #{outcome => Outcome, reasons => Reasons}};
        _ -> error
    end;
record_material({quod_dtx_complete, ?VERSION, GroupId, Origin, ManifestDigest,
                 Outcome, Rows, Applied}) ->
    case group_matches(GroupId, ManifestDigest) andalso valid_identity(Origin)
         andalso valid_outcome(Outcome) andalso reference_rows(Rows, generation)
         andalso lists:keymember(Origin, 1, Rows) andalso applied_rows(Applied, none) of
        true -> {ok, #{}};
        false -> error
    end;
record_material(_) -> error.

vote_intent(Group, Target, Bundle) ->
    digest({<<"quod.dtx.intent">>, ?VERSION, Group, Target, Bundle}).

own_bundle(none, _Target, {refused, _}) -> true;
own_bundle({Target, <<_:256>>, Blob, _}, Target, _) -> is_binary(Blob);
own_bundle(_, _, _) -> false.

-doc "Identify immutable pending vote custody independently of the uncommitted vote choice.".
-spec intent_id(admission_material()) -> <<_:256>>.
intent_id({{quod_dtx_vote, ?VERSION, _, _, _, _}, _, #{intent_id := Id}}) -> Id.

%% Installed state ---------------------------------------------------
%% One row represents a local role, including O. Only a positive, unresolved
%% row reserves material. No separately maintained conflict inventory exists.
%% Boundary decoding authenticates plans; installed turns only read them.

-doc "Create one empty role projection; the caller owns all mutation and application.".
-spec initial_projection(identity(), non_neg_integer()) -> projection().
initial_projection(Target, Generation) ->
    true = valid_identity(Target) andalso uint(Generation),
    #{target => Target, groups => #{}, apply_fences => #{}, generation => Generation}.

-doc """
Derive work from committed own rows, never a second recovery inventory.

O drives completion after either vote. Every other role may present the
manifest to O after the immutable deadline, after either vote and until its
own Resolve. The existing owner supplies tick time; this module never waits
or reads a clock. Observed O votes park that participant's existing worker,
not erase its durable enrollment or authorize it to decide an outcome.
""".
-spec recovery_rows(projection(), integer()) -> map().
recovery_rows(#{target := Target, groups := Groups}, Now) ->
    maps:filter(fun
        (_, #{material := {_, _, #{group := #{origin := Origin}}}})
          when Origin =:= Target -> true;
        (_, #{material := {_, _, #{group := #{vote_deadline_ms := Deadline}}},
              resolution := none}) -> Now > Deadline;
        (_, _) -> false
    end, Groups).

-doc "Validate a restored projection, including its retained authenticated own material.".
-spec valid_projection(term()) -> boolean().
valid_projection(#{target := Target, groups := Groups, apply_fences := Fences,
                   generation := Generation} = Projection)
  when map_size(Projection) =:= 4, is_map(Groups), is_map(Fences) ->
    valid_identity(Target) andalso uint(Generation) andalso
      maps:fold(fun(Id, Row, Valid) ->
          Valid andalso restored_role(Id, Target, Row) andalso
            role_fence_matches(Id, Row, Fences)
      end, true, Groups) andalso
      maps:fold(fun(Id, Fence, Valid) ->
          Valid andalso restored_fence(Id, Fence, Target, Groups)
      end, true, Fences);
valid_projection(_) -> false.

restored_role(Id, Target, #{material := {Vote, Digest, Meta}, ref := Ref,
                            resolution := Resolution} = Row)
  when map_size(Row) =:= 3, is_map(Meta) ->
    case admission_material(Vote) of
        {ok, {Vote, Digest, Checked}} ->
            Meta =:= Checked andalso
              record_target(Vote) =:= Target andalso group_id(Vote) =:= Id
              andalso exact_record_ref(Ref, Target, Digest)
              andalso restored_resolution(Resolution, Target)
              andalso (Resolution =:= none orelse maps:get(origin, maps:get(group, Meta)) =:= Target);
        error -> false
    end;
restored_role(_, _, _) -> false.

role_fence_matches(Id, #{resolution := none}, Fences) -> not maps:is_key(Id, Fences);
role_fence_matches(Id, #{resolution := #{ref := Ref, generation := Generation}}, Fences) ->
    case maps:get(Id, Fences, none) of
        #{slot := Slot, generation := Generation} -> Slot =:= ref_slot(Ref);
        _ -> false
    end.

restored_resolution(none, _) -> true;
restored_resolution(#{ref := Ref, outcome := Outcome, generation := Generation,
                       reasons := Reasons} = Resolution, Target)
  when map_size(Resolution) =:= 4 ->
    reference_target(Ref, Target) andalso uint(Generation) andalso
      case {Outcome, Reasons} of
          {commit, none} -> true;
          {abort, [_ | _]} -> true;
          _ -> false
      end;
restored_resolution(_, _) -> false.

restored_fence(<<_:256>> = Id, #{slot := Slot, generation := Generation,
                                blocking := Blocking} = Fence, Target, Groups)
  when map_size(Fence) =:= 3, is_boolean(Blocking) ->
    uint(Slot) andalso Slot > 0 andalso uint(Generation) andalso
      case maps:find(Id, Groups) of
          {ok, #{material := {_, _, #{group := #{origin := Target}}},
                 resolution := #{ref := Ref, generation := Generation}}} ->
              ref_slot(Ref) =:= Slot;
          error -> Blocking;
          _ -> false
      end;
restored_fence(_, _, _, _) -> false.

-doc "Classify checked material against the installed owner state; no clocks or signature work.".
-spec proposal_readiness(admission_material(), projection()) ->
          ready | {blocked, active_group | apply} | {refused, conflict} | stale.
proposal_readiness({Record, _, _} = Material,
                   #{groups := Groups, apply_fences := Fences, target := Target} = Projection) ->
    case record_target(Record) =:= Target of
        false -> stale;
        true ->
            Id = group_id(Record),
            case {record_kind(Record), maps:get(Id, Groups, none)} of
                {vote, none} ->
                    case Record of
                        {quod_dtx_vote, ?VERSION, _, _, _, {refused, _}} -> ready;
                        _ -> reservation_readiness(Material, Projection)
                    end;
                {resolve, none} ->
                    case Record of
                        {quod_dtx_resolve, ?VERSION, _, _, _, abort, _, _, none, 0, _} -> ready;
                        _ -> stale
                    end;
                {resolve, #{resolution := none}} -> ready;
                {complete, #{material := {_, _, #{group := #{origin := Target}}},
                             resolution := #{}}} ->
                    case maps:get(Id, Fences, none) of
                        #{blocking := true} -> {blocked, apply};
                        #{blocking := false} -> ready;
                        _ -> stale
                    end;
                _ -> stale
            end
    end.

-doc "Read own-plan reservations independently of the uncommitted vote's proposed verdict.".
-spec reservation_readiness(admission_material(), projection()) ->
          ready | {blocked, active_group} | {refused, conflict}.
reservation_readiness({{quod_dtx_vote, ?VERSION, _, Target, _, _} = Vote, _,
                       #{plans := Plans, group := Binding}},
                      #{target := Target, groups := Groups}) ->
    Descriptor = plan_descriptor(maps:get(Target, Plans)),
    Holders = [{Id, Other} ||
        {Id, #{material := {{quod_dtx_vote, ?VERSION, _, _, _, prepared}, _, Other},
               resolution := none}} <- maps:to_list(Groups),
        Id =/= group_id(Vote),
        descriptors_conflict(Descriptor, plan_descriptor(maps:get(Target, maps:get(plans, Other))))],
    %% Same-request contenders always wait: a losing retry cannot force a
    %% refusal of the original. Other requests keep the existing wait-die order.
    case Holders of
        [] -> ready;
        _ ->
            case lists:any(fun({Id, #{group := Holder}}) ->
                     Id < group_id(Vote) andalso not same_request_key(Binding, Holder)
                 end, Holders) of
                true -> {refused, conflict};
                false -> {blocked, active_group}
            end
    end.

plan_descriptor(Plan) -> maps:get(conflict_descriptor, quod_dtx:core(Plan)).
descriptors_conflict(#{reads := R, writes := W, custody := C},
                     #{reads := R1, writes := W1, custody := C1}) ->
    intersects(W, W1) orelse intersects(W, R1) orelse intersects(R, W1) orelse intersects(C, C1).
intersects(A, B) -> ordsets:intersection(A, B) =/= [].

-doc "Classify ordinary content against the same active positive-role reservations.".
-spec content_readiness(#transaction{}, projection()) -> ready | {blocked, active_group}.
content_readiness(#transaction{diff = Diff, read_check = Reads, effects = Effects},
                  #{groups := Groups, target := Target}) ->
    Descriptor = quod_dtx:conflict_descriptor(Diff, Reads, Effects),
    Conflict = maps:fold(fun
        (_, #{material := {{quod_dtx_vote, ?VERSION, _, _, _, prepared}, _, #{plans := Plans}},
              resolution := none}, Found) ->
            Found orelse descriptors_conflict(Descriptor, plan_descriptor(maps:get(Target, Plans)));
        (_, _, Found) -> Found
    end, false, Groups),
    case Conflict of true -> {blocked, active_group}; false -> ready end.

-doc "An exact group history holds at most Vote, Resolve and Complete, never an unbounded used set.".
-spec initial_group_history() -> group_history().
initial_group_history() -> #{group_id => none, records => #{}}.

-doc "Validate one bounded immutable phase-index row without loading any plan or ledger prefix.".
-spec valid_group_history(term()) -> boolean().
valid_group_history(#{group_id := none, records := Records} = History)
  when map_size(History) =:= 2, is_map(Records), map_size(Records) =:= 0 -> true;
valid_group_history(#{group_id := <<_:256>>, records := Records} = History)
  when map_size(History) =:= 2, is_map(Records),
       map_size(Records) >= 1, map_size(Records) =< 3 ->
    maps:fold(fun
        (Kind, #{digest := <<_:256>> = Digest, ref := Ref} = Row, Valid)
          when map_size(Row) =:= 2 ->
            Valid andalso valid_kind(Kind) andalso
              case quod_dtx:certified_ref_binding(Ref) of
                  {ok, _, _, Digest} -> true;
                  _ -> false
              end;
        (_, _, _) -> false
    end, true, Records);
valid_group_history(_) -> false.

-doc "Read the immutable first committed reference for one phase.".
-spec history_phase(vote | resolve | complete, group_history()) -> not_found | {ok, certified_reference()}.
history_phase(Kind, #{records := Records}) ->
    case maps:find(Kind, Records) of {ok, #{ref := Ref}} -> {ok, Ref}; error -> not_found end.

-doc """
Fold a checked control through the same local-role transition for source and target.
Before voting, the caller verifies outer authorship, foreign references, role
admission, certified block time and OCC. Certified replay uses its entry proof
and own prior custody, never ephemeral foreign-validation metadata or a network
lookup to rebuild state. Installed projections are trusted owner state; restored
projections enter valid_projection/1 once, not once per candidate or progress edge.
Effects use the existing ordered facts/effects application path.
""".
-spec reduce(control(), certified_reference(), group_history(), projection()) ->
          {ok, group_history(), projection(), list()} | {error, term()}.
reduce(Control, Ref, #{group_id := Prior, records := Records} = History,
       #{target := Target} = Projection) ->
    {Record, Digest, _} = Material = control_material(Control),
    Id = group_id(Record), Kind = record_kind(Record),
    case record_target(Record) =:= Target andalso (Prior =:= none orelse Prior =:= Id)
         andalso valid_group_history(History) andalso exact_record_ref(Ref, Target, Digest) of
        false -> transition_error(bad_binding);
        true ->
            case maps:find(Kind, Records) of
                {ok, #{digest := Digest}} -> {ok, History, Projection, []};
                {ok, _} -> transition_error(semantic_conflict);
                error ->
                    case transition(Kind, Id, Material, Ref, Records, Projection) of
                        {ok, Next, Effects} ->
                            {ok, History#{group_id := Id, records := Records#{
                                   Kind => #{digest => Digest, ref => Ref}}}, Next, Effects};
                        {error, _} = Error -> Error
                    end
            end
    end;
reduce(_, _, _, _) -> transition_error(malformed_state).

-doc "Reduce a canonical phase wave atomically; no partial result escapes a rejected member.".
-spec reduce_batch([{control(), certified_reference()}], map(), projection()) ->
          {ok, map(), projection(), list()} | {error, term()}.
reduce_batch(Controls, Histories, Projection) ->
    case canonical_control_wave([C || {C, _} <- Controls]) of
        true -> reduce_wave(Controls, Histories, Projection, [], certified);
        false -> transition_error(malformed_batch)
    end.

-doc "Preview the same reducer against an eligible installed parent; no second transition engine.".
-spec preview_batch([{control(), identity(), pos_integer(), <<_:256>>}], map(), projection()) ->
          {ok, map(), projection(), list()} | {error, term()}.
preview_batch(Candidates, Histories, Projection) ->
    Controls = [begin
        {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, Slot, Hash,
                      record_digest(Control), <<"quod.atomic.preview">>),
        {Control, Ref}
    end || {Control, {Ns, Anchor}, Slot, Hash} <- Candidates],
    case length(Controls) =:= length(Candidates) andalso
         canonical_control_wave([C || {C, _} <- Controls]) of
        true -> reduce_wave(Controls, Histories, Projection, [], preview);
        false -> transition_error(malformed_batch)
    end.

reduce_wave([], Histories, Projection, Items, _) ->
    {ok, Histories, Projection, lists:reverse(Items)};
reduce_wave([{Control, Ref} | Rest], Histories, Projection, Items, Mode) ->
    Id = group_id(Control),
    Result = case Mode =:= certified orelse proposal_readiness(control_material(Control), Projection) of
        Eligible when Eligible =:= true; Eligible =:= ready ->
            reduce(Control, Ref, maps:get(Id, Histories, initial_group_history()), Projection);
        {blocked, Reason} -> transition_error(Reason);
        {refused, Reason} -> transition_error(Reason);
        stale -> transition_error(stale)
    end,
    case Result of
        {ok, History, Next, Effects} ->
            reduce_wave(Rest, Histories#{Id => History}, Next,
                [#{control => Control, ref => Ref, history => History,
                   projection => Next, effects => Effects} | Items], Mode);
        {error, _} = Error -> Error
    end.

transition(vote, Id, Material, Ref, Records, #{groups := Groups} = Projection) ->
    case map_size(Records) =:= 0 andalso not maps:is_key(Id, Groups) of
        false -> transition_error(phase_reversal);
        true ->
            case proposal_readiness(Material, Projection) of
                ready ->
                    Row = #{material => Material, ref => Ref, resolution => none},
                    {ok, Projection#{groups := Groups#{Id => Row}}, []};
                {blocked, _} -> transition_error(active_group);
                {refused, _} -> transition_error(conflict_refused);
                stale -> transition_error(stale)
            end
    end;
transition(resolve, Id, {Record, _, #{reasons := Reasons}}, Ref, _Records,
           #{groups := Groups, target := Target} = Projection) ->
    {quod_dtx_resolve, ?VERSION, Id, Target, ManifestDigest, Outcome, OriginVote,
     _, OwnRef, Generation, _} = Record,
    Row = maps:get(Id, Groups, none),
    case resolve_binding(Row, Target, ManifestDigest, OriginVote, OwnRef) andalso
         resolve_own(Row, OwnRef, Outcome, Generation, Target) of
        {ok, OwnPlan} ->
            case apply_generation(Outcome, OwnPlan, maps:get(generation, Projection)) of
                {ok, Global} ->
                    {ok, Origin, _, _} = quod_dtx:certified_ref_binding(OriginVote),
                    Source = Origin =:= Target,
                    Resolution = #{ref => Ref, outcome => Outcome, generation => Generation,
                                   reasons => Reasons},
                    Groups1 = case Source of
                                  true -> Groups#{Id => Row#{resolution := Resolution}};
                                  false -> maps:remove(Id, Groups)
                              end,
                    Blocking = Outcome =:= commit andalso OwnPlan =/= none andalso
                                 maps:get(writes, plan_descriptor(OwnPlan)) =/= [],
                    Fences = maps:get(apply_fences, Projection),
                    Fences1 = case Source orelse Blocking of
                                  true -> Fences#{Id => #{slot => ref_slot(Ref),
                                               generation => Generation, blocking => Blocking}};
                                  false -> Fences
                              end,
                    {ok, Projection#{groups := Groups1, apply_fences := Fences1, generation := Global},
                     [resolution_effect(Id, Row, Outcome, Ref, Generation)]};
                error -> transition_error(generation_exhausted)
            end;
        _ -> transition_error(participant_phase)
    end;
transition(complete, Id, {Record, _, _}, Ref, Records,
           #{target := Target, groups := Groups, apply_fences := Fences} = Projection) ->
    {quod_dtx_complete, ?VERSION, Id, Target, ManifestDigest, Outcome, Rows, _} = Record,
    case maps:get(Id, Groups, none) of
        #{material := {_, _, #{group := #{origin := Target, participants := Roles,
                                          manifest_digest := ManifestDigest}}},
          resolution := #{ref := OwnRef, outcome := Outcome, generation := Generation,
                           reasons := Reasons}} ->
            Slot = ref_slot(OwnRef),
            case {lists:keyfind(Target, 1, Rows), maps:get(Id, Fences, none)} of
                {{Target, Supplied, Generation}, #{slot := Slot, generation := Generation}} ->
                    case maps:is_key(vote, Records) andalso maps:is_key(resolve, Records)
                         andalso [T || {T, _, _} <- Rows] =:= [T || {T, _} <- Roles]
                         andalso quod_dtx:same_certified_ref(Supplied, OwnRef) of
                        true ->
                            {ok, Projection#{groups := maps:remove(Id, Groups),
                                             apply_fences := maps:remove(Id, Fences)},
                             [completion_effect(Id, Outcome, Reasons, Ref)]};
                        false -> transition_error(bad_completion_set)
                    end;
                _ -> transition_error(bad_completion_set)
            end;
        _ -> transition_error(origin_phase)
    end.

%% The local vote owns the manifest. An unvoted abort carries no material;
%% its certified tombstone needs no foreign plan or replay-time fetch.
resolve_binding(Row, Target, ManifestDigest, OriginVote, OwnVote) ->
    {ok, Origin, _, _} = quod_dtx:certified_ref_binding(OriginVote),
    same_source_vote(Target, Origin, OwnVote, OriginVote) andalso
      case Row of
          none -> Target =/= Origin;
          #{material := {_, _, #{group := #{origin := Origin, manifest_digest := ManifestDigest}}}} -> true;
          _ -> false
      end.

resolve_own(none, none, abort, 0, _) -> {ok, none};
resolve_own(#{ref := Ref, resolution := none,
              material := {{quod_dtx_vote, ?VERSION, _, _, _, Choice}, _, #{plans := Plans}}},
            Supplied, Outcome, Generation, Target) ->
    Plan = maps:get(Target, Plans, none),
    Expected = case Plan of none -> 0; _ -> quod_dtx:overlay_generation(Plan) end,
    Delta = case Outcome of commit -> 1; abort -> 0 end,
    case quod_dtx:same_certified_ref(Ref, Supplied) andalso Generation =:= Expected + Delta
         andalso (Outcome =:= abort orelse (Choice =:= prepared andalso Plan =/= none)) of
        true -> {ok, Plan};
        false -> error
    end;
resolve_own(_, _, _, _, _) -> error.

apply_generation(commit, _Plan, Global) when Global < ?MAX_UINT64 -> {ok, Global + 1};
apply_generation(abort, _Plan, Global) -> {ok, Global};
apply_generation(_, _, _) -> error.

resolution_effect(Id, Row, Outcome, Ref, Generation) ->
    %% Carry the authenticated own material, not bytes for another decode.
    %% An unvoted abort has no local material and never reconstructs it.
    Own = case Row of none -> none; #{material := Material} -> Material end,
    {resolved, Id, Outcome, Own, Ref, Generation}.

completion_effect(Id, commit, none, Ref) -> {completed, Id, commit, Ref};
completion_effect(Id, abort, Reasons, Ref) -> {completed, Id, abort, Ref, Reasons}.

-doc "Open only the exact Resolve fence; a source marker survives until Complete.".
-spec acknowledge_resolve(<<_:256>>, pos_integer(), non_neg_integer(), projection()) ->
          {ok, projection()} | {error, stale_resolve_ack}.
acknowledge_resolve(Id, Slot, Generation, #{apply_fences := Fences, groups := Groups} = Projection) ->
    case maps:get(Id, Fences, none) of
        #{slot := Slot, generation := Generation} = Fence ->
            Next = case maps:is_key(Id, Groups) of
                       true -> Fences#{Id => Fence#{blocking := false}};
                       false -> maps:remove(Id, Fences)
                   end,
            {ok, Projection#{apply_fences := Next}};
        _ -> {error, stale_resolve_ack}
    end.

-doc "Install a verified suffix while preserving this owner's exact prefix apply acknowledgements.".
-spec install_projection(projection(), projection(), non_neg_integer()) -> projection().
install_projection(#{target := Target, apply_fences := Incoming} = Projection,
                   #{target := Target, apply_fences := Current}, Height) ->
    Projection#{apply_fences := maps:filtermap(
        fun(Group, #{slot := Slot, generation := Generation}) when Slot =< Height ->
                case maps:find(Group, Current) of
                    {ok, #{slot := Slot, generation := Generation} = Fence} -> {true, Fence};
                    error -> false
                end;
           (_, Fence) -> {true, Fence}
        end, Incoming)}.

exact_record_ref(Ref, Target, Digest) ->
    case quod_dtx:certified_ref_binding(Ref) of {ok, Target, _, Digest} -> true; _ -> false end.
ref_slot(Ref) -> {ok, _, Slot, _} = quod_dtx:certified_ref_binding(Ref), Slot.
transition_error(Reason) -> {error, {invalid_transition, Reason}}.

valid_choice(prepared) -> true;
valid_choice({refused, Blob}) ->
    case quod_wire_term:decode_failure_reasons(Blob) of
        {ok, [_ | _]} -> true;
        _ -> false
    end;
valid_choice(_) -> false.

outcome_references(commit, {all_prepared, Rows}) -> reference_rows(Rows, plain);
outcome_references(abort, {refused, Ref}) -> quod_dtx:validate_certified_ref(Ref);
outcome_references(_, _) -> false.

reference_rows(Rows, Mode) ->
    bounded(Rows, ?QUOD_MAX_DTX_PARTICIPANTS) andalso Rows =/= []
        andalso reference_rows(Rows, Mode, none).
reference_rows([], _Mode, _Previous) -> true;
reference_rows([{Target, Ref} | Rest], plain, Previous)
  when Previous =:= none; Previous < Target ->
    reference_target(Ref, Target) andalso reference_rows(Rest, plain, Target);
reference_rows([{Target, Ref, Generation} | Rest], generation, Previous)
  when Previous =:= none; Previous < Target ->
    uint(Generation) andalso reference_target(Ref, Target)
        andalso reference_rows(Rest, generation, Target);
reference_rows(_, _, _) -> false.

applied_rows(Rows, Previous) ->
    bounded(Rows, ?QUOD_MAX_DTX_PARTICIPANTS) andalso applied_rows_valid(Rows, Previous).
applied_rows_valid([], _) -> true;
applied_rows_valid([{Target, Certificate} | Rest], Previous)
  when Previous =:= none; Previous < Target ->
    case quod_applied_certificate:applied_certificate_binding(Certificate) of
        {ok, #{target := Target}} -> applied_rows_valid(Rest, Target);
        _ -> false
    end;
applied_rows_valid(_, _) -> false.

reference_target(Ref, Target) ->
    case quod_dtx:certified_ref_binding(Ref) of
        {ok, Target, _, _} -> true;
        _ -> false
    end.
group_matches(<<_:256>> = GroupId, <<_:256>> = ManifestDigest) ->
    GroupId =:= group_digest(ManifestDigest);
group_matches(_, _) -> false.
valid_identity({Ns, <<_:256>>}) -> is_binary(Ns) andalso byte_size(Ns) > 0;
valid_identity(_) -> false.
valid_outcome(commit) -> true;
valid_outcome(abort) -> true;
valid_outcome(_) -> false.
uint(N) -> is_integer(N) andalso N >= 0 andalso N =< ?MAX_UINT64.
bounded([], _) -> true;
bounded([_ | Rest], N) when N > 0 -> bounded(Rest, N - 1);
bounded(_, _) -> false.
within_limit(Term) -> erlang:external_size(Term) =< ?QUOD_MAX_DTX_BODY_BYTES.
bytes(Term) -> term_to_binary(Term, [deterministic]).
digest(Term) -> crypto:hash(sha256, bytes(Term)).
