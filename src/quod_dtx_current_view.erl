-module(quod_dtx_current_view).
-moduledoc """
Committee corroboration for DTX recovery and sealed read plans.

Applied verification freezes the committee certified by the exact Finalize and
asks distinct members of that committee for signed replies. `f + 1` replies
form one portable certificate that source validators can verify locally. Public
outcome lookup retains its separate certified-current-view rule. In both cases,
one Byzantine responder can never decide a claim or outcome.

Routes are identity-pinned transport hints, never committee evidence. There is
no owner process, second history cache, or retained proof object: every call
uses the shared `quod_foreign_log` cache and bounded temporary probes, and
returns `retry` whenever history, routing, membership, application, or a reply
is uncertain. One probe is created per validator key; that probe tries the
shared key resolver's current endpoint, the existing live candidates, and the
exact Finalize-era fallback sequentially after deduplication. The transport
still authenticates the expected key; no endpoint creates another vote or
request id.

Read certification uses the same frozen-view routing and quorum collector. A
target validator checks the sealed read-only plan through the ordinary Prepare
validator at its current committed head, then signs the plan digest and the
immutable claim of its certified ledger anchor. Different valid finality-proof
subsets for that same claim remain interchangeable evidence. The collector
keeps the plan vocabulary opaque.
""".

-include("quod_proof_limits.hrl").

-export([submit_operation/4, submit_claim_application/5,
         submit_operation_to/5,
         certify_applied_many/3, certify_reads/3, lookup_outcome/4,
         threshold/1,
         sign_applied_vote/8, verify_applied_certificate/3,
         valid_applied_certificate_shape/1,
         applied_certificate_binding/1]).
-export_type([source/0, claim/0, applied_certificate/0]).

-ifdef(TEST).
-export([test_certify_applied/6, test_certify_applied_many/4,
         test_certify_reads/4,
         test_lookup_outcome/5,
         test_production_dependencies/0,
         test_read_anchor_source/4,
         test_endpoint_failure_disposition/2,
         test_submit_operation_candidates/2]).
-endif.

-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(PROBE_CLEANUP_MS, 1000).
-define(APPLIED_CERTIFICATE_VERSION, 1).
-define(APPLIED_VOTE_VERSION, 1).

-type identity() :: {binary(), <<_:256>>}.
-type local_source() :: quod_simplex:history_view().
-type source() ::
        {local, local_source()} |
        {remote, [{<<_:256>>, [term()]}]}.
-type claim() ::
        #{target := identity(),
          group_id := <<_:256>>,
          finalize_ref := quod_dtx:certified_ref(),
          generation := non_neg_integer(),
          verdict := commit | abort}.
-type applied_certificate() ::
        {quod_dtx_applied_certificate, 1, <<_:256>>, identity(), <<_:256>>,
         <<_:256>>, quod_dtx:certified_ref(), non_neg_integer(),
         commit | abort, [{<<_:256>>, <<_:512>>}]}.
-type many_result() :: {verified, applied_certificate()} | retry.
-type outcome_result() ::
        {ok, map()} | {error, retry | not_found | invalid_request}.

-doc "Sign one exact Finalize-applied vote with a validator's node identity.".
-spec sign_applied_vote(<<_:256>>, identity(), <<_:256>>, <<_:256>>,
                        quod_dtx:certified_ref(), non_neg_integer(),
                        commit | abort, quod_identity:signer()) ->
          {ok, {<<_:256>>, <<_:512>>}} | error.
sign_applied_vote(NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
                  Generation, Verdict,
                  #{pubkey := <<_:256>> = Signer, key := _} = Identity) ->
    case applied_statement(
           NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
           Generation, Verdict) of
        {ok, Statement} ->
            Signature = quod_identity:sign(
                          applied_vote_bytes(Statement), Identity),
            case Signature of
                <<_:512>> -> {ok, {Signer, Signature}};
                _ -> error
            end;
        error ->
            error
    end;
sign_applied_vote(_NetworkIdentity, _Target, _CommitteeId, _GroupId,
                  _FinalizeRef, _Generation, _Verdict, _Identity) ->
    error.

-doc "Return the exact statement carried by a bounded applied certificate.".
-spec applied_certificate_binding(applied_certificate()) -> {ok, map()} | error.
applied_certificate_binding(
  {quod_dtx_applied_certificate, ?APPLIED_CERTIFICATE_VERSION,
   <<_:256>> = NetworkIdentity, Target, <<_:256>> = CommitteeId,
   <<_:256>> = GroupId, FinalizeRef, Generation, Verdict, Signatures}
  = Certificate) ->
    case applied_statement(
           NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
           Generation, Verdict) of
        {ok, Statement} ->
            {ok, Target, AppliedThrough, _Digest} =
                quod_dtx:certified_ref_binding(FinalizeRef),
            case valid_applied_signatures(Signatures) andalso
                 erlang:external_size(Certificate) =<
                     ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES of
                true ->
                    {ok, #{network_identity => NetworkIdentity,
                           target => Target, committee_id => CommitteeId,
                           group_id => GroupId, finalize_ref => FinalizeRef,
                           applied_through => AppliedThrough,
                           generation => Generation, verdict => Verdict,
                           statement => Statement,
                           signatures => Signatures}};
                false -> error
            end;
        error -> error
    end;
applied_certificate_binding(_Certificate) ->
    error.

-doc "Cheap bounded shape check for an untrusted applied certificate.".
-spec valid_applied_certificate_shape(term()) -> boolean().
valid_applied_certificate_shape(Certificate) ->
    case applied_certificate_binding(Certificate) of
        {ok, _} -> true;
        error -> false
    end.

-doc "Verify one certificate against the exact certified Finalize evidence.".
-spec verify_applied_certificate(applied_certificate(), <<_:256>>, map()) ->
          boolean().
verify_applied_certificate(Certificate, NetworkIdentity,
                           #{identity := Target,
                             committee := Committee,
                             committee_id := CommitteeId} = Evidence) ->
    case applied_certificate_binding(Certificate) of
        {ok, #{network_identity := NetworkIdentity,
               target := Target, committee_id := CommitteeId,
               group_id := GroupId, finalize_ref := FinalizeRef,
               generation := Generation, verdict := Verdict,
               statement := Statement, signatures := Signatures}} ->
            case exact_finalize_binding(Evidence, FinalizeRef) of
                {ok, GroupId, FinalizeRef, Generation, Verdict} ->
                    case quod_quorum:committee_size(Committee) of
                        {ok, N} when N > 0 ->
                            Needed = applied_threshold(N),
                            case length(Signatures) =:= Needed of
                                true ->
                                    case quod_quorum:sanitize_at_least(
                                           Committee,
                                           applied_vote_bytes(Statement),
                                           Signatures, Needed) of
                                        {ok, Signatures} -> true;
                                        _ -> false
                                    end;
                                false -> false
                            end;
                        _ -> false
                    end;
                _ ->
                    false
            end;
        _ ->
            false
    end;
verify_applied_certificate(_Certificate, _NetworkIdentity, _Evidence) ->
    false.

-doc """
Submit one correlated durable-operation request to an exact ontology.

The co-hosted and remote cases deliberately share this owner.  Route hints
remain transport hints: the endpoint response must still correlate with the
exact request, and the target transaction's foreign evidence is verified by
the ordinary consensus path independently on every validator.
""".
-spec submit_operation(binary(), identity(), quod_dtx_endpoint:request(),
                       pos_integer()) ->
          {ok, quod_dtx_endpoint:response()} |
          {error, busy | not_ready | invalid_request | timeout |
                  connection_lost}.
submit_operation(OwnerNs, {TargetNs, <<_:256>> = Anchor} = Target,
                 Request, TimeoutMs)
  when is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0 ->
    BoundedTimeout = min(
                       TimeoutMs,
                       ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS),
    case quod_dtx_endpoint:encode_request(TargetNs, Request, []) of
        {ok, _} ->
            submit_operation_target(
              OwnerNs, Target, Anchor, Request,
              quod_time:mono_ms() + BoundedTimeout);
        {error, _} ->
            {error, invalid_request}
    end;
submit_operation(_OwnerNs, _Target, _Request, _TimeoutMs) ->
    {error, invalid_request}.

-doc "Submit a claimed application through the route implied by its effect custody.".
-spec submit_claim_application(binary(), identity(), tuple(),
                               quod_dtx_endpoint:request(), pos_integer()) ->
          {ok, quod_dtx_endpoint:response()} |
          {error, busy | not_ready | invalid_request | timeout |
                  connection_lost}.
submit_claim_application(OwnerNs, Target, Claim,
                         {apply_claim, _, Target, _} = Request, TimeoutMs) ->
    case quod_transaction:remote_claim_route(Claim, Target) of
        shared ->
            submit_operation(OwnerNs, Target, Request, TimeoutMs);
        {private, TargetNode} ->
            submit_operation_to(
              OwnerNs, Target, TargetNode, Request, TimeoutMs);
        error ->
            {error, invalid_request}
    end;
submit_claim_application(_OwnerNs, _Target, _Claim, _Request, _TimeoutMs) ->
    {error, invalid_request}.

-doc "Submit to one exact authenticated target node, for private custody recovery.".
-spec submit_operation_to(binary(), identity(), <<_:256>>,
                          quod_dtx_endpoint:request(), pos_integer()) ->
          {ok, quod_dtx_endpoint:response()} |
          {error, busy | not_ready | invalid_request | timeout |
                  connection_lost}.
submit_operation_to(OwnerNs, {TargetNs, <<_:256>> = Anchor} = Target,
                    <<_:256>> = TargetNode, Request, TimeoutMs)
  when is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0 ->
    BoundedTimeout = min(TimeoutMs, ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS),
    case quod_dtx_endpoint:encode_request(TargetNs, Request, []) of
        {ok, _} ->
            submit_operation_exact_target(
              OwnerNs, Target, Anchor, TargetNode, Request,
              quod_time:mono_ms() + BoundedTimeout);
        {error, _} ->
            {error, invalid_request}
    end;
submit_operation_to(_OwnerNs, _Target, _TargetNode, _Request, _TimeoutMs) ->
    {error, invalid_request}.

submit_operation_exact_target(
  OwnerNs, {TargetNs, _} = Target, Anchor, TargetNode, Request, Deadline) ->
    case {TargetNode =:= node_key(), quod_reg:where({quod_simplex, TargetNs})} of
        {true, Pid} when is_pid(Pid) ->
            case quod_simplex:genesis_hash(TargetNs) of
                Anchor ->
                    operation_response(
                      Request,
                      quod_simplex:dtx_endpoint_local(
                        TargetNs, Request, [], remaining_positive(Deadline)));
                _ ->
                    submit_operation_exact_routes(
                      OwnerNs, Target, TargetNode, Request, Deadline)
            end;
        _ ->
            submit_operation_exact_routes(
              OwnerNs, Target, TargetNode, Request, Deadline)
    end.

submit_operation_exact_routes(
  OwnerNs, {TargetNs, _} = Target, TargetNode, Request, Deadline) ->
    case quod_foreign_log:route_hints(Target, []) of
        {ok, Routes} ->
            case lists:keyfind(TargetNode, 1, Routes) of
                {TargetNode, Endpoints} ->
                    submit_operation_candidates(
                      OwnerNs, TargetNs,
                      [{TargetNode, Endpoint} || Endpoint <- Endpoints],
                      Request, Deadline, not_ready);
                false ->
                    {error, not_ready}
            end;
        {error, _} ->
            {error, not_ready}
    end.

submit_operation_target(OwnerNs, {TargetNs, _} = Target, Anchor,
                        Request, Deadline) ->
    case quod_reg:where({quod_simplex, TargetNs}) of
        Pid when is_pid(Pid) ->
            case quod_simplex:genesis_hash(TargetNs) of
                Anchor ->
                    operation_response(
                      Request,
                      quod_simplex:dtx_endpoint_local(
                        TargetNs, Request, [], remaining_positive(Deadline)));
                _ ->
                    submit_operation_routes(
                      OwnerNs, Target, Request, Deadline)
            end;
        undefined ->
            submit_operation_routes(OwnerNs, Target, Request, Deadline)
    end.

submit_operation_routes(OwnerNs, {TargetNs, _} = Target,
                        Request, Deadline) ->
    case quod_foreign_log:route_hints(Target, []) of
        {ok, Routes} ->
            submit_operation_candidates(
              OwnerNs, TargetNs,
              [{PeerKey, Endpoint}
               || {PeerKey, Endpoints} <- Routes,
                  Endpoint <- Endpoints],
              Request, Deadline, not_ready);
        {error, _} ->
            {error, not_ready}
    end.

submit_operation_candidates(_OwnerNs, _TargetNs, [], _Request,
                            _Deadline, Last) ->
    {error, Last};
submit_operation_candidates(OwnerNs, TargetNs, Candidates, Request,
                            Deadline, Last) ->
    submit_operation_candidates(
      OwnerNs, TargetNs, Candidates, Request, Deadline, Last,
      fun(Key, Endpoint, Remaining) ->
              quod_simplex:dtx_endpoint_request(
                OwnerNs, TargetNs, Key, Endpoint, Request, [], Remaining)
      end).

submit_operation_candidates(_OwnerNs, _TargetNs, [], _Request,
                            _Deadline, Last, _Attempt) ->
    {error, Last};
submit_operation_candidates(OwnerNs, TargetNs,
                            [{PeerKey, Endpoint} | Rest], Request,
                            Deadline, Last, Attempt) ->
    case remaining(Deadline) of
        0 -> {error, Last};
        Remaining ->
            Result = Attempt(PeerKey, Endpoint, Remaining),
            case operation_response(Request, Result) of
                {ok, _} = Ok -> Ok;
                {error, Reason} ->
                    case endpoint_failure_disposition(Request, Reason) of
                        stop -> {error, Reason};
                        next ->
                            submit_operation_candidates(
                              OwnerNs, TargetNs, Rest, Request,
                              Deadline, Reason, Attempt)
                    end
            end
    end.

%% Cancellation mutates a node-private idempotent journal row. Once any exact
%% endpoint attempt fails, its sole custody owner parks until the directory
%% publishes a real route edge; walking stale alternatives here would turn a
%% transport failure into an immediate semantic retry. A timeout or authenticated
%% link loss is likewise uncertain for every write/read request and must return
%% to its existing history/recovery owner instead of resubmitting automatically.
endpoint_failure_disposition({cancel_operation_effect, _, _, _}, _Reason) -> stop;
endpoint_failure_disposition(_Request, timeout) -> stop;
endpoint_failure_disposition(_Request, connection_lost) -> stop;
endpoint_failure_disposition(_Request, _Reason) -> next.

operation_response(Request, {ok, Response, _ValidationSidecar}) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> {ok, Response};
        false -> {error, invalid_request}
    end;
operation_response(_Request, {error, Reason}) ->
    {error, Reason}.

remaining_positive(Deadline) ->
    max(1, remaining(Deadline)).

-doc """
Build participant-applied certificates concurrently under one bounded deadline.

Each request carries the exact Finalize evidence already verified by the
coordinator. For valid input the returned list is aligned with `Requests`. An
exact certificate is retained as `{verified, Certificate}` even when another
participant is temporarily unavailable; only that participant's row is
`retry`. A caller authorizing Complete must still require every row.
""".
-spec certify_applied_many(binary(), [{source(), claim(), map()}], pos_integer()) ->
          {ok, [many_result()]} | {error, invalid_request}.
certify_applied_many(OwnerNs, Requests, TimeoutMs) ->
    certify_applied_many_with(
      OwnerNs, Requests, TimeoutMs, production_dependencies()).

-doc "Build one `f + 1` certificate within the original absolute monotonic deadline.".
-spec certify_reads(binary(), {source(), binary()}, integer()) ->
          {ok, quod_read_certificate:certificate()} |
          {error, invalid_request | conflict_retry | retry}.
certify_reads(OwnerNs, Request, Deadline) ->
    certify_reads_with(
      OwnerNs, Request, Deadline, production_dependencies()).

-doc """
Resolve one anchored public outcome through a frozen certified current view.

Terminal and ledger-derived pending statuses require `f + 1` identical
current-validator replies. After a group is absent from that quorum snapshot,
the certified view may prove its coordinator retired; if that key is still
current, only its exact admission-bound coordinator barrier may decide local
pre-Begin state. Ordinary absence is never made definitive by this API and
remains `retry`. The absolute monotonic deadline includes any initial local
history capture performed by the caller.
""".
-spec lookup_outcome(binary(), source(), term(), integer()) ->
          outcome_result().
lookup_outcome(OwnerNs, Source, OutcomeRef, Deadline) ->
    lookup_outcome_with(
      OwnerNs, Source, OutcomeRef, Deadline, production_dependencies()).

lookup_outcome_with(OwnerNs, Source, OutcomeRef, Deadline, Dependencies)
  when is_integer(Deadline) ->
    case remaining(Deadline) of
        0 -> {error, retry};
        TimeoutMs -> lookup_outcome_before_deadline(
                       OwnerNs, Source, OutcomeRef, TimeoutMs, Deadline, Dependencies)
    end;
lookup_outcome_with(_OwnerNs, _Source, _OutcomeRef, _Deadline, _Dependencies) ->
    {error, invalid_request}.

lookup_outcome_before_deadline(
  OwnerNs, Source, OutcomeRef, TimeoutMs, Deadline, Dependencies) ->
    case valid_outcome_request(OwnerNs, Source, OutcomeRef, TimeoutMs) of
        {ok, Target} ->
            case call_current_view(
                   Source, {identity, Target}, Deadline, Dependencies) of
                {ok, View} ->
                    lookup_outcome_view(
                      OwnerNs, Source, OutcomeRef, Target, View,
                      Deadline, Dependencies);
                {error, _} ->
                    {error, retry}
            end;
        error ->
            {error, invalid_request}
    end.

production_dependencies() ->
    #{view =>
          fun({local, LocalSource}, {identity, Identity}, _Timeout) ->
                  local_current_view(LocalSource, Identity);
             ({remote, Routes}, {identity, Identity}, Timeout) ->
                  quod_foreign_log:current(Routes, Identity, Timeout)
          end,
      local =>
          fun(TargetNs, Request, Timeout) ->
                  quod_simplex:dtx_endpoint_local(
                    TargetNs, Request, [], Timeout)
          end,
      remote =>
          fun(Owner, TargetNs, PeerKey, Endpoint, Request, Timeout) ->
                  quod_simplex:dtx_endpoint_request(
                    Owner, TargetNs, PeerKey, Endpoint, Request, [], Timeout)
          end,
      exact_entry =>
          fun({local, LocalSource}, Ref, Timeout) ->
                  quod_foreign_log:verify_local(
                    LocalSource, Ref, entry, Timeout);
             ({remote, _Routes}, Ref, Timeout) ->
                  quod_foreign_log:verify_reference(Ref, entry, Timeout)
          end,
      resolve => fun quod_quic:resolve/1,
      node_key => fun node_key/0,
      network_identity => fun quod_ontology:network_identity/0}.

%% Current-view admission uses the same owner turn as its byte source. The
%% apply-sent frontier is deliberately distinct from the committed ledger tip;
%% this map does not introduce a Prolog MVCC snapshot or acknowledgement.
local_current_view(
  #{identity := Identity, applied := Applied,
    projection := #{committee := Committee, committee_id := CommitteeId,
                    validator_routes := Routes, dtx := Dtx}} = Source,
  Identity) when Applied > 0, Committee =/= [] ->
    case quod_simplex:history_view_live(Source) of
        true ->
            {ok, #{identity => Identity, slot => Applied,
                   generation => maps:get(generation, Dtx),
                   committee => Committee, committee_id => CommitteeId,
                   route_candidates => lists:keysort(
                     1, [{Peer, [Endpoint]}
                         || Peer <- Committee,
                            {ok, Endpoint} <- [maps:find(Peer, Routes)],
                            quod_quic:valid_endpoint(Endpoint)])}};
        false -> {error, not_ready}
    end;
local_current_view(_Source, _Identity) ->
    {error, not_ready}.

%% Validators may attest a newer anchor while the initial source is pinned.
%% Borrow that exact reference's bytes once from the original owner, without
%% changing the admitted committee, sealed plan, or proof snapshot. A later
%% retirement cannot invalidate an already-admitted read certificate, so this
%% byte-only capture requires committed history, not current validator role.
read_anchor_source(
  {local, #{identity := Identity, slot := Height}} = Source,
  Identity, {Slot, _BlockHash, _RecordDigest}, _Deadline) when Slot =< Height ->
    {ok, Source};
read_anchor_source(
  {local, #{owner := Owner, identity := Identity} = View},
  Identity, {Slot, _BlockHash, _RecordDigest}, Deadline) ->
    case quod_simplex:history_view_live(View) of
        true ->
            case quod_simplex:history_view({Owner, Identity}, committed, Deadline) of
                {ok, #{owner := Owner, identity := Identity,
                       slot := CurrentHeight} = Current}
                  when Slot =< CurrentHeight ->
                    {ok, {local, Current}};
                _ -> {error, not_ready}
            end;
        false -> {error, not_ready}
    end;
read_anchor_source({remote, _Routes} = Source, _Identity, _Claim, _Deadline) ->
    {ok, Source};
read_anchor_source(_Source, _Identity, _Claim, _Deadline) ->
    {error, invalid_request}.

certify_applied_with(
  OwnerNs, Source, Claim, Evidence, TimeoutMs, Dependencies) ->
    case valid_request(OwnerNs, Source, Claim, TimeoutMs) of
        {ok, Target, GroupId, FinalizeRef, Generation, Verdict} ->
            Deadline = quod_time:mono_ms() + TimeoutMs,
            case dependency_network_identity(Dependencies) of
                {ok, NetworkIdentity} ->
                    verify_view(
                      OwnerNs, Source, NetworkIdentity, Target,
                      GroupId, FinalizeRef, Generation, Verdict,
                      Evidence, Deadline, Dependencies);
                {error, _} ->
                    {error, retry}
            end;
        error ->
            {error, invalid_request}
    end.

certify_reads_with(OwnerNs, {Source, PlanBlob}, Deadline, Dependencies)
  when is_integer(Deadline) ->
    case remaining(Deadline) of
        0 -> {error, retry};
        TimeoutMs -> certify_reads_before_deadline(
                       OwnerNs, Source, PlanBlob, TimeoutMs, Deadline, Dependencies)
    end;
certify_reads_with(_OwnerNs, _Request, _Deadline, _Dependencies) ->
    {error, invalid_request}.

certify_reads_before_deadline(
  OwnerNs, Source, PlanBlob, TimeoutMs, Deadline, Dependencies) ->
    case valid_read_request(OwnerNs, Source, PlanBlob, TimeoutMs) of
        {ok, Plan, Target} ->
            case call_current_view(
                   Source, {identity, Target}, Deadline, Dependencies) of
                {ok, View} ->
                    certify_reads_view(
                      OwnerNs, Source, Plan, PlanBlob, Target, View,
                      Deadline, Dependencies);
                {error, _} ->
                    {error, retry}
            end;
        error ->
            {error, invalid_request}
    end.

valid_read_request(OwnerNs, Source, PlanBlob, TimeoutMs)
  when is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    case {valid_source(Source), quod_dtx:decode(PlanBlob)} of
        {true, {ok, Plan}} ->
            case quod_dtx:verify(Plan) andalso
                 quod_dtx:diff_ops(Plan) =:= 0 andalso
                 quod_dtx:effects_count(Plan) =:= 0 andalso
                 maps:get(read_functors, quod_dtx:core(Plan), 0) > 0 of
                true -> {ok, Plan, quod_dtx:target(Plan)};
                false -> error
            end;
        _ -> error
    end;
valid_read_request(_OwnerNs, _Source, _PlanBlob, _TimeoutMs) ->
    error.

certify_reads_view(
  OwnerNs, Source, Plan, PlanBlob, Target, View, Deadline, Dependencies) ->
    case valid_identity_current_view(Target, View) of
        {ok, Committee, CommitteeId, MinimumSlot, Routes} ->
            case MinimumSlot >= quod_dtx:base_height(Plan) of
                true ->
                    Sources = probe_sources(
                                Source, Committee, Routes, Dependencies),
                    Needed = threshold(length(Committee)),
                    case length(Sources) >= Needed andalso
                         remaining(Deadline) > 0 of
                        true ->
                            collect_read_votes(
                              OwnerNs, Source, Sources, Plan, PlanBlob,
                              CommitteeId, Needed,
                              Deadline, Dependencies);
                        false ->
                            {error, retry}
                    end;
                false ->
                    {error, retry}
            end;
        _ ->
            {error, retry}
    end.

collect_read_votes(
  OwnerNs, Source, Sources, Plan, PlanBlob, CommitteeId, Needed, Deadline,
  Dependencies) ->
    Probe =
        fun(Key, ProbeSource) ->
                case probe_read_attest(
                       OwnerNs, Key, ProbeSource, Plan, PlanBlob,
                       CommitteeId, Deadline, Dependencies) of
                    {ok, Binding, SignedRow, AnchorRef} ->
                        {signed, {read, Binding}, SignedRow, AnchorRef};
                    conflict_retry ->
                        {ok, conflict_retry};
                    ignore -> ignore
                end
        end,
    case collect_quorum(
           read_certificate_probe, Sources, Needed, Deadline, Probe) of
        {ok, {signed, {read, {Target, ProofId, PlanDigest, AnchorClaim,
                              CommitteeId}}, Rows}} ->
            case verified_read_anchor(
                   Source, Target, AnchorClaim, Rows, Deadline,
                   Dependencies) of
                {ok, AnchorRef, Signatures} ->
                    case quod_read_certificate:new(
                           Target, ProofId, PlanDigest, AnchorRef,
                           CommitteeId, Signatures) of
                        {ok, Certificate} -> {ok, Certificate};
                        error -> {error, retry}
                    end;
                error ->
                    {error, retry}
            end;
        {ok, conflict_retry} ->
            {error, conflict_retry};
        _ ->
            {error, retry}
    end.

certify_applied_many_with(OwnerNs, Requests, TimeoutMs, Dependencies)
  when is_list(Requests), Requests =/= [],
       length(Requests) =< ?QUOD_MAX_DTX_PARTICIPANTS,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    case lists:all(
           fun({Source, Claim, Evidence}) when is_map(Evidence) ->
                   case valid_request(
                          OwnerNs, Source, Claim, TimeoutMs) of
                       {ok, Target, GroupId, FinalizeRef, Generation,
                        Verdict} ->
                           valid_finalize_evidence(
                             Target, GroupId, FinalizeRef, Generation,
                             Verdict, Evidence) =/= error;
                       error -> false
                   end;
              (_) -> false
           end, Requests) of
        true ->
            certify_applied_many_requests(
              OwnerNs, Requests, TimeoutMs, Dependencies);
        false ->
            {error, invalid_request}
    end;
certify_applied_many_with(_OwnerNs, _Requests, _TimeoutMs, _Dependencies) ->
    {error, invalid_request}.

certify_applied_many_requests(OwnerNs, Requests, TimeoutMs, Dependencies) ->
    Parent = self(),
    TraceCtx = quod_trace:context(),
    VerifyRef = make_ref(),
    Pending =
        lists:foldl(
          fun({Index, {Source, Claim, Evidence}}, Acc) ->
                  {Pid, Monitor} = spawn_opt(
                    fun() ->
                        Result = quod_trace:with_optional_span(
                                   TraceCtx, <<"quod.dtx.applied.verify">>, internal, #{},
                                   fun() -> certify_applied_with(
                                              OwnerNs, Source, Claim, Evidence,
                                              TimeoutMs, Dependencies) end),
                        Parent ! {dtx_current_view_many, VerifyRef, self(),
                                  Index, Result}
                    end, [link, monitor]),
                  Acc#{Pid => {Monitor, Index}}
          end, #{}, lists:enumerate(Requests)),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    collect_many_results(VerifyRef, Pending, #{}, Deadline).

collect_many_results(VerifyRef, Pending, Results, _Deadline)
  when map_size(Pending) =:= 0 ->
    flush_worker_results(dtx_current_view_many, VerifyRef),
    {ok, aligned_many_results(Results)};
collect_many_results(VerifyRef, Pending, Results, Deadline) ->
    case remaining(Deadline) of
        0 ->
            stop_workers(dtx_current_view_many, VerifyRef, Pending),
            {ok, aligned_many_results(mark_pending_retry(Pending, Results))};
        Wait ->
            receive
                {dtx_current_view_many, VerifyRef, Pid, Index, {ok, View}}
                  when is_map_key(Pid, Pending) ->
                    case maps:take(Pid, Pending) of
                        {{Monitor, Index}, Rest} ->
                            _ = erlang:demonitor(Monitor, [flush]),
                            collect_many_results(
                              VerifyRef, Rest,
                              Results#{Index => {verified, View}},
                              Deadline);
                        {{Monitor, ExpectedIndex}, Rest} ->
                            _ = erlang:demonitor(Monitor, [flush]),
                            collect_many_results(
                              VerifyRef, Rest,
                              Results#{ExpectedIndex => retry}, Deadline)
                    end;
                {dtx_current_view_many, VerifyRef, Pid, _Index, {error, retry}}
                  when is_map_key(Pid, Pending) ->
                    {{Monitor, ExpectedIndex}, Rest} = maps:take(Pid, Pending),
                    _ = erlang:demonitor(Monitor, [flush]),
                    collect_many_results(
                      VerifyRef, Rest, Results#{ExpectedIndex => retry},
                      Deadline);
                {dtx_current_view_many, VerifyRef, Pid, _Index,
                 {error, invalid_request}}
                  when is_map_key(Pid, Pending) ->
                    {{Monitor, _ExpectedIndex}, Rest} =
                        maps:take(Pid, Pending),
                    _ = erlang:demonitor(Monitor, [flush]),
                    stop_workers(dtx_current_view_many, VerifyRef, Rest),
                    {error, invalid_request};
                {'DOWN', Monitor, process, Pid, _Reason}
                  when is_map_key(Pid, Pending) ->
                    case maps:get(Pid, Pending) of
                        {Monitor, Index} ->
                            Rest = maps:remove(Pid, Pending),
                            collect_many_results(
                              VerifyRef, Rest, Results#{Index => retry},
                              Deadline);
                        _ ->
                            collect_many_results(
                              VerifyRef, Pending, Results, Deadline)
                    end
            after Wait ->
                stop_workers(dtx_current_view_many, VerifyRef, Pending),
                {ok,
                 aligned_many_results(mark_pending_retry(Pending, Results))}
            end
    end.

mark_pending_retry(Pending, Results) ->
    maps:fold(
      fun(_Pid, {_Monitor, Index}, Acc) -> Acc#{Index => retry} end,
      Results, Pending).

aligned_many_results(Results) ->
    [Result || {_Index, Result} <-
                   lists:keysort(1, maps:to_list(Results))].

valid_request(OwnerNs, Source,
              #{target := {TargetNs, <<_:256>> = Anchor} = Target,
                group_id := <<_:256>> = GroupId,
                finalize_ref := FinalizeRef,
                generation := Generation,
                verdict := Verdict} = Claim,
              TimeoutMs)
  when is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_binary(TargetNs), byte_size(TargetNs) > 0,
       map_size(Claim) =:= 5,
       is_integer(Generation), Generation >= 0, Generation =< ?MAX_UINT64,
       (Verdict =:= commit orelse Verdict =:= abort),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    case {valid_source(Source),
          quod_dtx:certified_ref_binding(FinalizeRef)} of
        {true, {ok, {TargetNs, Anchor}, _Slot, <<_:256>>}} ->
            {ok, Target, GroupId, FinalizeRef, Generation, Verdict};
        _ ->
            error
    end;
valid_request(_OwnerNs, _Source, _Claim, _TimeoutMs) ->
    error.

valid_outcome_request(OwnerNs, Source, OutcomeRef, TimeoutMs)
  when is_binary(OwnerNs), byte_size(OwnerNs) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS ->
    case {valid_source(Source), quod_outcome:ref_identity(OutcomeRef)} of
        {true, {ok, Target}} -> {ok, Target};
        _ -> error
    end;
valid_outcome_request(_OwnerNs, _Source, _OutcomeRef, _TimeoutMs) ->
    error.

lookup_outcome_view(OwnerNs, Source, OutcomeRef, Target, View,
                    Deadline, Dependencies) ->
    case valid_identity_current_view(Target, View) of
        {ok, Committee, CommitteeId, MinimumSlot, Routes} ->
            Sources = probe_sources(
                        Source, Committee, Routes, Dependencies),
            Needed = threshold(length(Committee)),
            case length(Sources) >= Needed andalso remaining(Deadline) > 0 of
                true ->
                    Claim = {Target, CommitteeId, MinimumSlot, OutcomeRef},
                    case collect_outcomes(
                           OwnerNs, Sources, Claim, Needed, Deadline,
                           Dependencies) of
                        {ok, not_found} ->
                            resolve_quorum_absence(
                              OwnerNs, Sources, Committee, Claim,
                              Deadline, Dependencies);
                        {ok, Status} ->
                            {ok, Status};
                        retry ->
                            {error, retry}
                    end;
                false ->
                    {error, retry}
            end;
        error ->
            {error, retry}
    end.

resolve_quorum_absence(
  _OwnerNs, _Sources, _Committee,
  {_Target, _CommitteeId, _MinimumSlot,
   {transaction, _, _, _}}, _Deadline, _Dependencies) ->
    %% A quorum can corroborate that an ordinary transaction is absent from
    %% its applied snapshots, but no durable exclusion barrier proves that it
    %% was never handed off. Preserve uncertainty.
    {error, retry};
resolve_quorum_absence(
  OwnerNs, Sources, Committee,
  {Target, CommitteeId, MinimumSlot,
   {group, _, _, Coordinator, _, _} = GroupRef},
  Deadline, Dependencies) ->
    case lists:member(Coordinator, Committee) of
        false ->
            %% The certified current view itself proves that the admission
            %% generation named by GroupRef can no longer author Begin.
            {ok, #{status => rejected, reason => coordinator_retired,
                   ref => GroupRef}};
        true ->
            case lists:keyfind(Coordinator, 1, Sources) of
                {Coordinator, CoordinatorSource} ->
                    probe_outcome_barrier(
                      OwnerNs, Coordinator, CoordinatorSource,
                      {Target, CommitteeId, MinimumSlot, GroupRef},
                      Deadline, Dependencies);
                false ->
                    {error, retry}
            end
    end;
resolve_quorum_absence(
  _OwnerNs, _Sources, _Committee, _Claim, _Deadline, _Dependencies) ->
    {error, retry}.

valid_source(
  {local, #{owner := Owner, identity := {Ns, <<_:256>>},
            slot := Slot, applied := Applied,
            snapshot := _Snapshot, projection := Projection}}) ->
    is_pid(Owner) andalso is_binary(Ns) andalso byte_size(Ns) > 0 andalso
        is_integer(Slot) andalso Slot > 0 andalso
        is_integer(Applied) andalso Applied >= 0 andalso Applied =< Slot andalso
        is_map(Projection);
valid_source({remote, Routes}) when is_list(Routes), Routes =/= [],
                                    length(Routes) =< ?MAX_VALIDATORS ->
    quod_foreign_log:valid_route_candidates(Routes);
valid_source(_) ->
    false.

call_current_view(Source, Basis, Deadline, Dependencies) ->
    case remaining(Deadline) of
        0 -> {error, retry};
        Remaining ->
            %% Freezing the committee and asking that committee are one
            %% operation. Do not let a cold history fetch consume the caller's
            %% entire deadline and make the mandatory corroboration probe
            %% impossible. A retry can reuse the shared history cache.
            Timeout = erlang:max(1, Remaining - erlang:max(1, Remaining div 4)),
            View = maps:get(view, Dependencies),
            try View(Source, Basis, Timeout)
            catch exit:_ -> {error, retry}
            end
    end.

verify_view(OwnerNs, Source, NetworkIdentity, Target, GroupId, FinalizeRef,
            Generation, Verdict, Evidence, Deadline, Dependencies) ->
    case valid_finalize_evidence(
           Target, GroupId, FinalizeRef, Generation, Verdict, Evidence) of
        {ok, Committee, CommitteeId, Routes} ->
            Sources = probe_sources(
                        Source, Committee, Routes, Dependencies),
            Needed = threshold(length(Committee)),
            case length(Sources) >= Needed andalso remaining(Deadline) > 0 of
                true ->
                    Claim = {NetworkIdentity, Target, CommitteeId, GroupId,
                             FinalizeRef, Generation, Verdict},
                    case collect_applied(
                           OwnerNs, Sources, Claim, Needed, Deadline,
                           Dependencies) of
                        {ok, Certificate} -> {ok, Certificate};
                        retry -> {error, retry}
                    end;
                false ->
                    {error, retry}
            end;
        error ->
            {error, retry}
    end.

valid_finalize_evidence(Target, GroupId, FinalizeRef, Generation, Verdict,
                        Evidence) ->
    case {exact_finalize_binding(Evidence, FinalizeRef),
          finalize_committee_view(Target, Evidence)} of
        {{ok, GroupId, FinalizeRef, Generation, Verdict},
         {ok, Committee, CommitteeId, Routes}} ->
            {ok, Committee, CommitteeId, Routes};
        _ -> error
    end.

exact_finalize_binding(
  #{identity := Target, phase := finalize, control := Control,
    entry := Entry}, FinalizeRef) ->
    %% Certified-history verification owns proof authority.  The applied
    %% certificate and this replica's entry may carry different valid quorum
    %% subsets, but both must name one immutable Finalize claim.
    case {quod_dtx:control_kind(Control),
          quod_dtx:recovery_phase(quod_dtx:control_body(Control)),
          quod_dtx:certified_entry_ref(Target, Entry, Control)} of
        {finalize,
         {ok, #{kind := finalize, group_id := <<_:256>> = GroupId,
                generation := Generation, verdict := Verdict}},
         {ok, EntryRef}}
          when is_integer(Generation), Generation >= 0,
               Generation =< ?MAX_UINT64,
               (Verdict =:= commit orelse Verdict =:= abort) ->
            case quod_dtx:same_certified_ref(EntryRef, FinalizeRef) of
                true ->
                    {ok, GroupId, FinalizeRef, Generation, Verdict};
                false ->
                    error
            end;
        _ -> error
    end;
exact_finalize_binding(_Evidence, _FinalizeRef) ->
    error.

finalize_committee_view(
  Target,
  #{identity := Target, committee := Committee,
    committee_id := <<_:256>> = CommitteeId, routes := RouteMap})
  when is_list(Committee), Committee =/= [],
       length(Committee) =< ?MAX_VALIDATORS,
       is_map(RouteMap), map_size(RouteMap) =< ?MAX_VALIDATORS ->
    Routes = lists:keysort(
               1,
               [{Key, [Endpoint]}
                || {Key, Endpoint} <- maps:to_list(RouteMap)]),
    case Committee =:= lists:usort(Committee) andalso
         lists:all(fun valid_key/1, Committee) andalso
         valid_historical_routes(Routes, Committee) of
        true -> {ok, Committee, CommitteeId, Routes};
        false -> error
    end;
finalize_committee_view(_Target, _Evidence) ->
    error.

%% A co-hosted validator needs no transport route to attest. Historical
%% routes are therefore an optional, authenticated reachability aid rather
%% than a precondition for a valid Finalize-era committee.
valid_historical_routes(Routes, Committee) ->
    lists:all(
      fun({Key, [Endpoint]}) ->
              lists:member(Key, Committee) andalso
                  quod_quic:valid_endpoint(Endpoint);
         (_) ->
              false
      end, Routes).

valid_identity_current_view(
  Target,
  #{identity := Target, slot := Slot, generation := Generation,
    committee := Committee, committee_id := <<_:256>> = CommitteeId,
    route_candidates := Routes} = View)
  when map_size(View) =:= 6,
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation >= 0, Generation =< ?MAX_UINT64,
       is_list(Committee), Committee =/= [],
       length(Committee) =< ?MAX_VALIDATORS,
       is_list(Routes), length(Routes) =< ?MAX_VALIDATORS ->
    case Committee =:= lists:usort(Committee) andalso
         lists:all(fun valid_key/1, Committee) andalso
         valid_routes(Routes, Committee) of
        true -> {ok, Committee, CommitteeId, Slot, Routes};
        false -> error
    end;
valid_identity_current_view(_Target, _View) ->
    error.

valid_key(<<_:256>>) -> true;
valid_key(_) -> false.

valid_routes(Routes, Committee) ->
    quod_foreign_log:valid_route_candidates(Routes) andalso
        lists:all(
          fun({Key, _Endpoints}) -> lists:member(Key, Committee) end,
          Routes).

probe_sources(Source, Committee, Routes, Dependencies) ->
    LocalKey = case Source of
                   {local, _} -> dependency_node_key(Dependencies);
                   {remote, _} -> none
               end,
    SourceRoutes = case Source of
                       {remote, Candidates} -> Candidates;
                       {local, _} -> []
                   end,
    lists:filtermap(
      fun(Key) when Key =:= LocalKey, LocalKey =/= none ->
              {true, {Key, local}};
         (Key) ->
              case applied_probe_endpoints(
                     Key, dependency_resolved_endpoint(Key, Dependencies),
                     SourceRoutes, Routes) of
                  [_ | _] = Endpoints ->
                      {true, {Key, {remote, Endpoints}}};
                  [] -> false
              end
      end, Committee).

%% The exact Finalize fixes who may attest; endpoints remain reachability
%% only. Merge the shared key resolver's current endpoint before the caller's
%% identity-pinned candidates and the historical Finalize fallback, so a retired
%% holder remains reachable after moving. Transport still authenticates Key, and
%% no route can add a signer outside Committee.
applied_probe_endpoints(
  Key, ResolvedEndpoint, SourceRoutes, HistoricalRoutes) ->
    Resolved = case ResolvedEndpoint of
                   {ok, Endpoint} -> [Endpoint];
                   error -> []
               end,
    Live = case lists:keyfind(Key, 1, SourceRoutes) of
               {Key, Endpoints0} -> Endpoints0;
               false -> []
           end,
    Historical = case lists:keyfind(Key, 1, HistoricalRoutes) of
                     {Key, Endpoints1} -> Endpoints1;
                     false -> []
                 end,
    unique_endpoints(Resolved ++ Live ++ Historical, #{}, []).

dependency_resolved_endpoint(Key, Dependencies) ->
    Resolve = maps:get(resolve, Dependencies),
    case Resolve(Key) of
        {ok, Endpoint} ->
            case quod_quic:valid_endpoint(Endpoint) of
                true -> {ok, Endpoint};
                false -> error
            end;
        _ ->
            error
    end.

unique_endpoints([], _Seen, Acc) ->
    lists:reverse(Acc);
unique_endpoints([Endpoint | Rest], Seen, Acc) ->
    case maps:is_key(Endpoint, Seen) of
        true -> unique_endpoints(Rest, Seen, Acc);
        false -> unique_endpoints(
                   Rest, Seen#{Endpoint => true}, [Endpoint | Acc])
    end.

dependency_node_key(Dependencies) ->
    NodeKey = maps:get(node_key, Dependencies),
    case NodeKey() of
        <<_:256>> = Key -> Key;
        _ -> none
    end.

dependency_network_identity(Dependencies) ->
    case maps:find(network_identity, Dependencies) of
        {ok, NetworkIdentity} ->
            try NetworkIdentity() of
                {ok, <<_:256>> = Identity} -> {ok, Identity};
                _ -> {error, unavailable}
            catch _:_ -> {error, unavailable}
            end;
        error ->
            {error, unavailable}
    end.

node_key() ->
    case application:get_env(quod, node_pubkey) of
        {ok, <<_:256>> = Key} -> Key;
        _ -> none
    end.

collect_applied(OwnerNs, Sources, Claim, Needed, Deadline, Dependencies) ->
    Probe = fun(Key, Source) ->
                    case probe_applied(
                           OwnerNs, Key, Source, Claim, Deadline,
                           Dependencies) of
                        {ok, SignedRow} ->
                            {signed, applied, SignedRow, none};
                        ignore -> ignore
                    end
            end,
    case collect_quorum(
           dtx_applied_probe, Sources, Needed, Deadline, Probe) of
        {ok, {signed, applied, Rows}} ->
            applied_certificate(Claim, signed_rows(Rows));
        _ ->
            retry
    end.

collect_outcomes(OwnerNs, Sources, Claim, Needed, Deadline, Dependencies) ->
    Probe = fun(Key, Source) ->
                    probe_outcome(
                      OwnerNs, Key, Source, Claim, Deadline, Dependencies)
            end,
    case collect_quorum(
           dtx_outcome_probe, Sources, Needed, Deadline, Probe) of
        {ok, Outcome} -> {ok, Outcome};
        retry -> retry
    end.

collect_quorum(Tag, Sources, Needed, Deadline, Probe) ->
    Parent = self(),
    TraceCtx = quod_trace:context(),
    ProbeRef = make_ref(),
    Pending = lists:foldl(
                fun({Key, Source}, Acc) ->
                    {Pid, Monitor} = spawn_opt(
                      fun() ->
                          Result = quod_trace:with_optional_span(
                                     TraceCtx, <<"quod.dtx.quorum.probe">>, client,
                                     #{'quod.probe.family' => atom_to_binary(Tag, utf8)},
                                     fun() -> Probe(Key, Source) end),
                          Parent ! {Tag, ProbeRef, self(), Key, Result}
                      end, [link, monitor]),
                    Acc#{Pid => {Monitor, Key}}
                end, #{}, Sources),
    collect_quorum_results(
      Tag, ProbeRef, Pending, Needed, #{}, Deadline).

collect_quorum_results(Tag, ProbeRef, Pending, _Needed, _Counts, _Deadline)
  when map_size(Pending) =:= 0 ->
    flush_worker_results(Tag, ProbeRef),
    retry;
collect_quorum_results(Tag, ProbeRef, Pending, Needed, Counts, Deadline) ->
    case remaining(Deadline) of
        0 ->
            stop_workers(Tag, ProbeRef, Pending),
            retry;
        Wait ->
            receive
                {Tag, ProbeRef, Pid, Key, Result}
                  when is_map_key(Pid, Pending) ->
                    case maps:take(Pid, Pending) of
                        {{Monitor, Key}, Rest} ->
                            _ = erlang:demonitor(Monitor, [flush]),
                            case count_match(Result, Needed, Counts) of
                                {reached, Value} ->
                                    stop_workers(Tag, ProbeRef, Rest),
                                    {ok, Value};
                                {continue, Counts1} ->
                                    collect_quorum_results(
                                      Tag, ProbeRef, Rest, Needed,
                                      Counts1, Deadline)
                            end;
                        {{Monitor, _OtherKey}, Rest} ->
                            _ = erlang:demonitor(Monitor, [flush]),
                            collect_quorum_results(
                              Tag, ProbeRef, Rest, Needed, Counts, Deadline)
                    end;
                {'DOWN', Monitor, process, Pid, _Reason}
                  when is_map_key(Pid, Pending) ->
                    case maps:get(Pid, Pending) of
                        {Monitor, _Key} ->
                            collect_quorum_results(
                              Tag, ProbeRef, maps:remove(Pid, Pending),
                              Needed, Counts, Deadline);
                        _ ->
                            collect_quorum_results(
                              Tag, ProbeRef, Pending, Needed,
                              Counts, Deadline)
                    end
            after Wait ->
                stop_workers(Tag, ProbeRef, Pending),
                retry
            end
    end.

count_match({ok, Value}, Needed, Counts) ->
    Count = maps:get(Value, Counts, 0) + 1,
    case Count >= Needed of
        true -> {reached, Value};
        false -> {continue, Counts#{Value => Count}}
    end;
count_match(
  {signed, Value, {<<_:256>> = Signer, <<_:512>> = Signature}, Witness},
  Needed, Counts) ->
    Key = {signed, Value},
    Rows0 = maps:get(Key, Counts, #{}),
    Rows = Rows0#{Signer => {Signature, Witness}},
    case map_size(Rows) >= Needed of
        true ->
            {reached,
             {signed, Value,
              [{RowSigner, RowSignature, RowWitness}
               || {RowSigner, {RowSignature, RowWitness}} <-
                      lists:keysort(1, maps:to_list(Rows))]}};
        false ->
            {continue, Counts#{Key => Rows}}
    end;
count_match(_Ignored, _Needed, Counts) ->
    {continue, Counts}.

signed_rows(Rows) ->
    [{Signer, Signature} || {Signer, Signature, _Witness} <- Rows].

verified_read_anchor(Source, Target, Claim, Rows, Deadline, Dependencies) ->
    %% Votes establish the immutable entry claim. The certified-history owner
    %% separately validates one carried finality proof at the entry's actual
    %% committee era; proof-subset bytes are neither identity nor authority by
    %% themselves. This is the same exact-reference verifier used downstream.
    Candidates = lists:uniq([Ref || {_Signer, _Signature, Ref} <- Rows]),
    %% Equivalent finality proofs all witness the same claim. Capture newer
    %% local bytes once, before trying those proofs, rather than once per
    %% candidate or after any invalid proof.
    ExactSourceResult = case remaining(Deadline) of
                            0 -> {error, retry};
                            _ -> read_anchor_source(Source, Target, Claim, Deadline)
                        end,
    case ExactSourceResult of
        {ok, ExactSource} ->
            case verify_read_anchor_candidates(
                   ExactSource, Target, Claim, Candidates, Deadline,
                   Dependencies) of
                {ok, AnchorRef} -> {ok, AnchorRef, signed_rows(Rows)};
                error -> error
            end;
        {error, _} -> error
    end.

verify_read_anchor_candidates(
  _Source, _Target, _Claim, [], _Deadline, _Dependencies) ->
    error;
verify_read_anchor_candidates(
  Source, Target, {Slot, BlockHash, RecordDigest} = Claim,
  [Ref | Rest], Deadline, Dependencies) ->
    case remaining(Deadline) of
        0 ->
            error;
        Wait ->
            Verify = maps:get(exact_entry, Dependencies),
            case Verify(Source, Ref, Wait) of
                {ok, #{identity := Target, slot := Slot,
                       block_hash := BlockHash,
                       record_digest := RecordDigest}} ->
                    {ok, Ref};
                _ ->
                    verify_read_anchor_candidates(
                      Source, Target, Claim, Rest, Deadline, Dependencies)
            end
    end.

stop_workers(Tag, Ref, Pending) ->
    maps:foreach(
      fun(Pid, _MonitorAndKey) ->
              _ = unlink(Pid),
              exit(Pid, kill)
      end, Pending),
    CleanupDeadline = quod_time:mono_ms() + ?PROBE_CLEANUP_MS,
    await_worker_downs(Tag, Ref, Pending, CleanupDeadline),
    flush_worker_results(Tag, Ref).

await_worker_downs(_Tag, _Ref, Pending, _Deadline)
  when map_size(Pending) =:= 0 ->
    ok;
await_worker_downs(Tag, Ref, Pending, Deadline) ->
    case remaining(Deadline) of
        0 ->
            maps:foreach(
              fun(_Pid, {Monitor, _Key}) ->
                      _ = erlang:demonitor(Monitor, [flush])
              end, Pending);
        Wait ->
            receive
                {'DOWN', Monitor, process, Pid, _Reason}
                  when is_map_key(Pid, Pending) ->
                    case maps:get(Pid, Pending) of
                        {Monitor, _Key} ->
                            await_worker_downs(
                              Tag, Ref, maps:remove(Pid, Pending), Deadline);
                        _ ->
                            await_worker_downs(Tag, Ref, Pending, Deadline)
                    end;
                {Tag, Ref, _Pid, _Key, _Result} ->
                    await_worker_downs(Tag, Ref, Pending, Deadline)
            after Wait ->
                maps:foreach(
                  fun(_Pid, {Monitor, _Key}) ->
                          _ = erlang:demonitor(Monitor, [flush])
                  end, Pending)
            end
    end.

flush_worker_results(Tag, Ref) ->
    receive
        {Tag, Ref, _Pid, _Key, _Result} ->
            flush_worker_results(Tag, Ref)
    after 0 ->
        ok
    end.

probe_outcome(OwnerNs, PeerKey, Source,
              {{TargetNs, _Anchor} = Target, CommitteeId, MinimumSlot,
               OutcomeRef},
              Deadline, Dependencies) ->
    Request = {outcome, request_id(), OutcomeRef,
               CommitteeId, MinimumSlot},
    probe_outcome_source(
      Source, OwnerNs, TargetNs, PeerKey, Request, Target,
      CommitteeId, Deadline, Dependencies).

probe_outcome_source(
  {remote, Endpoints}, OwnerNs, TargetNs, PeerKey, Request,
  Target, CommitteeId, Deadline, Dependencies) ->
    walk_remote_candidates(
      Endpoints, Deadline,
      fun(Endpoint, AttemptDeadline) ->
          call_endpoint(
            OwnerNs, TargetNs, PeerKey, {remote, Endpoint}, Request,
            AttemptDeadline, Dependencies)
      end,
      fun(Result) ->
          case outcome_response(Request, Target, CommitteeId, Result) of
              ignore -> continue;
              Accepted -> {done, Accepted}
          end
      end,
      ignore);
probe_outcome_source(
  local, OwnerNs, TargetNs, PeerKey, Request, Target,
  CommitteeId, Deadline, Dependencies) ->
    outcome_response(
      Request, Target, CommitteeId,
      call_endpoint(
        OwnerNs, TargetNs, PeerKey, local, Request,
        Deadline, Dependencies)).

outcome_response(
  Request, Target, CommitteeId,
  {ok, {outcome, _RequestId, Target, CommitteeId, _AppliedFloor,
        Outcome} = Response}) ->
    case quod_dtx_endpoint:correlates(Request, Response) andalso
         quorum_outcome_allowed(Outcome) of
        true -> {ok, Outcome};
        false -> ignore
    end;
outcome_response(_Request, _Target, _CommitteeId, _Result) ->
    ignore.

%% `pending_begin` is journal/handoff state owned only by the exact
%% coordinator. It is deliberately excluded from current-view voting and is
%% obtained only through the barrier below after quorum-certified absence.
quorum_outcome_allowed(
  #{status := pending, phase := pending_begin}) -> false;
quorum_outcome_allowed(not_found) -> true;
quorum_outcome_allowed(#{status := _}) -> true;
quorum_outcome_allowed(_) -> false.

probe_outcome_barrier(
  OwnerNs, Coordinator, Source,
  {{TargetNs, _Anchor} = Target, CommitteeId, MinimumSlot, GroupRef},
  Deadline, Dependencies) ->
    Request = {outcome_barrier, request_id(), GroupRef,
               CommitteeId, MinimumSlot},
    probe_outcome_barrier_source(
      Source, OwnerNs, TargetNs, Coordinator, Request, Target,
      CommitteeId, GroupRef, Deadline, Dependencies).

probe_outcome_barrier_source(
  {remote, Endpoints}, OwnerNs, TargetNs, Coordinator, Request,
  Target, CommitteeId, GroupRef, Deadline, Dependencies) ->
    walk_remote_candidates(
      Endpoints, Deadline,
      fun(Endpoint, AttemptDeadline) ->
          call_endpoint(
            OwnerNs, TargetNs, Coordinator, {remote, Endpoint}, Request,
            AttemptDeadline, Dependencies)
      end,
      fun(Result) ->
          case barrier_response(
                 Request, Target, CommitteeId, GroupRef, Result) of
              {error, retry} -> continue;
              Accepted -> {done, Accepted}
          end
      end,
      {error, retry});
probe_outcome_barrier_source(
  local, OwnerNs, TargetNs, Coordinator, Request, Target,
  CommitteeId, GroupRef, Deadline, Dependencies) ->
    barrier_response(
      Request, Target, CommitteeId, GroupRef,
      call_endpoint(
        OwnerNs, TargetNs, Coordinator, local, Request,
        Deadline, Dependencies)).

barrier_response(
  Request, Target, CommitteeId, GroupRef,
  {ok, {outcome_barrier, _RequestId, Target, CommitteeId,
        _AppliedFloor, Status} = Response}) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> barrier_result(Status, GroupRef);
        false -> {error, retry}
    end;
barrier_response(_Request, _Target, _CommitteeId, _GroupRef, _Result) ->
    {error, retry}.

barrier_result(pending_begin, GroupRef) ->
    {ok, #{status => pending, phase => pending_begin, ref => GroupRef}};
barrier_result(coordinator_retired, GroupRef) ->
    {ok, #{status => rejected, reason => coordinator_retired,
           ref => GroupRef}};
barrier_result(not_found, _GroupRef) ->
    {error, not_found};
barrier_result(_Status, _GroupRef) ->
    {error, retry}.

call_endpoint(OwnerNs, TargetNs, PeerKey, Source, Request,
              Deadline, Dependencies) ->
    case remaining(Deadline) of
        0 -> {error, timeout};
        Timeout ->
            try
                Result = case Source of
                             local ->
                                 Local = maps:get(local, Dependencies),
                                 Local(TargetNs, Request, Timeout);
                             {remote, Endpoint} ->
                                 Remote = maps:get(remote, Dependencies),
                                 Remote(OwnerNs, TargetNs, PeerKey, Endpoint,
                                        Request, Timeout)
                         end,
                case Result of
                    {ok, Response, _ValidationSidecar} -> {ok, Response};
                    Other -> Other
                end
            catch exit:_ -> {error, not_ready}
            end
    end.

probe_read_attest(
  OwnerNs, PeerKey, Source, Plan, PlanBlob, CommitteeId, Deadline,
  Dependencies) ->
    {TargetNs, _Anchor} = Target = quod_dtx:target(Plan),
    Request = {read_attest, request_id(), PlanBlob},
    probe_read_attest_source(
      Source, OwnerNs, TargetNs, PeerKey, Request, Target,
      quod_dtx:proof_id(Plan), quod_dtx:digest(Plan),
      CommitteeId, Deadline, Dependencies).

probe_read_attest_source(
  {remote, Endpoints}, OwnerNs, TargetNs, PeerKey, Request,
  Target, ProofId, PlanDigest, CommitteeId, Deadline, Dependencies) ->
    walk_remote_candidates(
      Endpoints, Deadline,
      fun(Endpoint, AttemptDeadline) ->
          call_endpoint(
            OwnerNs, TargetNs, PeerKey, {remote, Endpoint}, Request,
            AttemptDeadline, Dependencies)
      end,
      fun(Result) ->
          case read_attest_response_vote(
                 Request, Target, ProofId, PlanDigest, CommitteeId,
                 PeerKey, Result) of
              {ok, _, _, _} = Vote -> {done, Vote};
              conflict_retry -> {done, conflict_retry};
              ignore -> continue
          end
      end,
      ignore);
probe_read_attest_source(
  local, OwnerNs, TargetNs, PeerKey, Request,
  Target, ProofId, PlanDigest, CommitteeId, Deadline, Dependencies) ->
    read_attest_response_vote(
      Request, Target, ProofId, PlanDigest, CommitteeId, PeerKey,
      call_endpoint(
        OwnerNs, TargetNs, PeerKey, local, Request,
        Deadline, Dependencies)).

read_attest_response_vote(
  Request, Target, ProofId, PlanDigest, CommitteeId, ExpectedSigner,
  {ok, {read_attest, _RequestId, Target, ProofId, PlanDigest, AnchorRef,
        CommitteeId,
        ExpectedSigner, Signature} = Response}) ->
    case {quod_dtx_endpoint:correlates(Request, Response),
          quod_read_certificate:verify_vote(
            Target, ProofId, PlanDigest, AnchorRef,
            CommitteeId, ExpectedSigner, Signature),
          quod_dtx:certified_ref_claim(AnchorRef)} of
        {true, true,
         {ok, {Target, Slot, BlockHash, RecordDigest}}} ->
            {ok,
             {Target, ProofId, PlanDigest,
              {Slot, BlockHash, RecordDigest}, CommitteeId},
             {ExpectedSigner, Signature}, AnchorRef};
        _ ->
            ignore
    end;
read_attest_response_vote(
  Request, _Target, _ProofId, _PlanDigest, _CommitteeId,
  _ExpectedSigner,
  {ok, {error, _RequestId, conflict_retry} = Response}) ->
    case quod_dtx_endpoint:correlates(Request, Response) of
        true -> conflict_retry;
        false -> ignore
    end;
read_attest_response_vote(
  _Request, _Target, _ProofId, _PlanDigest, _CommitteeId,
  _ExpectedSigner, _Result) ->
    ignore.

probe_applied(OwnerNs, PeerKey, Source,
              {NetworkIdentity, {TargetNs, _Anchor} = Target, CommitteeId,
               GroupId, FinalizeRef, Generation, Verdict},
              Deadline, Dependencies) ->
    Request = {applied, request_id(), GroupId, FinalizeRef,
               Generation, Verdict},
    probe_applied_source(
      Source, OwnerNs, TargetNs, PeerKey, Request, Target,
      NetworkIdentity, CommitteeId, Deadline, Dependencies).

probe_applied_source(
  {remote, Endpoints}, OwnerNs, TargetNs, PeerKey, Request,
  Target, NetworkIdentity, CommitteeId, Deadline, Dependencies) ->
    walk_remote_candidates(
      Endpoints, Deadline,
      fun(Endpoint, AttemptDeadline) ->
          call_endpoint(
            OwnerNs, TargetNs, PeerKey, {remote, Endpoint}, Request,
            AttemptDeadline, Dependencies)
      end,
      fun(Result) ->
          case applied_response_vote(
                 Request, NetworkIdentity, Target, CommitteeId, PeerKey,
                 Result) of
              {ok, _} = Vote -> {done, Vote};
              ignore -> continue
          end
      end,
      ignore);
probe_applied_source(
  local, OwnerNs, TargetNs, PeerKey, Request,
  Target, NetworkIdentity, CommitteeId, Deadline, Dependencies) ->
    Result = call_endpoint(
               OwnerNs, TargetNs, PeerKey, local, Request,
               Deadline, Dependencies),
    applied_response_vote(
      Request, NetworkIdentity, Target, CommitteeId, PeerKey, Result).

applied_response_vote(
  Request, NetworkIdentity, Target, CommitteeId, ExpectedSigner,
  {ok, {applied, _RequestId, Target, CommitteeId, GroupId,
         FinalizeRef, Generation, Verdict, ExpectedSigner, Signature}
       = Response}) ->
    case quod_dtx_endpoint:correlates(Request, Response) andalso
         applied_vote_valid(
           NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
           Generation, Verdict, ExpectedSigner, Signature) of
        true -> {ok, {ExpectedSigner, Signature}};
        false -> ignore
    end;
applied_response_vote(_Request, _NetworkIdentity, _Target, _CommitteeId,
                      _ExpectedSigner, _Result) ->
    ignore.

applied_certificate(
  {NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
   Generation, Verdict}, Signatures) ->
    Certificate =
        {quod_dtx_applied_certificate, ?APPLIED_CERTIFICATE_VERSION,
         NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
         Generation, Verdict, Signatures},
    case valid_applied_certificate_shape(Certificate) of
        true -> {ok, Certificate};
        false -> retry
    end.

applied_statement(NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
                  Generation, Verdict)
  when is_binary(NetworkIdentity), byte_size(NetworkIdentity) =:= 32,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64,
       (Verdict =:= commit orelse Verdict =:= abort) ->
    case {valid_identity(Target), quod_dtx:certified_ref_binding(FinalizeRef)} of
        {true, {ok, Target, _Slot, _Digest}}
          when is_binary(CommitteeId), byte_size(CommitteeId) =:= 32,
               is_binary(GroupId), byte_size(GroupId) =:= 32 ->
            {ok, {quod_dtx_applied_vote, ?APPLIED_VOTE_VERSION,
                  NetworkIdentity, Target, CommitteeId, GroupId,
                  FinalizeRef, Generation, Verdict}};
        _ -> error
    end;
applied_statement(_NetworkIdentity, _Target, _CommitteeId, _GroupId,
                  _FinalizeRef, _Generation, _Verdict) ->
    error.

applied_vote_bytes(Statement) ->
    term_to_binary(Statement, [deterministic]).

applied_vote_valid(NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
                   Generation, Verdict, Signer, Signature) ->
    case applied_statement(
           NetworkIdentity, Target, CommitteeId, GroupId, FinalizeRef,
           Generation, Verdict) of
        {ok, Statement} ->
            quod_identity:verify(
              Signature, applied_vote_bytes(Statement), Signer);
        error -> false
    end.

valid_applied_signatures([_ | _] = Signatures) ->
    quod_quorum:valid_signature_list(Signatures, ?MAX_VALIDATORS) andalso
        Signatures =:= lists:ukeysort(1, Signatures);
valid_applied_signatures(_) ->
    false.

valid_identity({Ns, <<_:256>>}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0;
valid_identity(_) ->
    false.

request_id() ->
    crypto:strong_rand_bytes(?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS div 8).

threshold(N) ->
    N - quod_simplex:quorum(N) + 1.

applied_threshold(N) ->
    threshold(N).

remaining(Deadline) ->
    max(0, Deadline - quod_time:mono_ms()).

candidate_deadline(Deadline, CandidatesLeft) ->
    Now = quod_time:mono_ms(),
    Remaining = max(0, Deadline - Now),
    case Remaining of
        0 -> Deadline;
        _ -> Now + max(1, Remaining div max(1, CandidatesLeft))
    end.

walk_remote_candidates([], _Deadline, _Attempt, _Accept, Exhausted) ->
    Exhausted;
walk_remote_candidates(
  [Endpoint | Rest], Deadline, Attempt, Accept, Exhausted) ->
    Result = Attempt(
               Endpoint, candidate_deadline(Deadline, length(Rest) + 1)),
    case Accept(Result) of
        {done, Accepted} -> Accepted;
        continue ->
            walk_remote_candidates(
              Rest, Deadline, Attempt, Accept, Exhausted)
    end.

-ifdef(TEST).
test_certify_applied(
  OwnerNs, Source, Claim, Evidence, TimeoutMs, Dependencies) ->
    certify_applied_with(
      OwnerNs, Source, Claim, Evidence, TimeoutMs, Dependencies).

test_certify_applied_many(OwnerNs, Requests, TimeoutMs, Dependencies) ->
    certify_applied_many_with(
      OwnerNs, Requests, TimeoutMs, Dependencies).

test_certify_reads(OwnerNs, Request, Deadline, Dependencies) ->
    certify_reads_with(OwnerNs, Request, Deadline, Dependencies).

test_lookup_outcome(OwnerNs, Source, OutcomeRef, Deadline, Dependencies) ->
    lookup_outcome_with(
      OwnerNs, Source, OutcomeRef, Deadline, Dependencies).

test_production_dependencies() -> production_dependencies().

test_read_anchor_source(Source, Target, Claim, Deadline) ->
    read_anchor_source(Source, Target, Claim, Deadline).

test_endpoint_failure_disposition(Request, Reason) ->
    endpoint_failure_disposition(Request, Reason).

test_submit_operation_candidates(Request, Results) when is_list(Results) ->
    Counter = atomics:new(1, []),
    ResultTuple = list_to_tuple(Results),
    Candidates =
        [{<<N:256>>, {"127.0.0.1", 10000 + N}}
         || N <- lists:seq(1, length(Results))],
    Attempt =
        fun(_PeerKey, _Endpoint, _Remaining) ->
                Index = atomics:add_get(Counter, 1, 1),
                element(Index, ResultTuple)
        end,
    Result = submit_operation_candidates(
               <<"quod:test-owner">>, <<"quod:test-target">>, Candidates,
               Request, quod_time:mono_ms() + 1000, not_ready, Attempt),
    {Result, atomics:get(Counter, 1)}.

-endif.
