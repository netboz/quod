-module(quod_client_goal_target).
-moduledoc """
One target-side executor for local and forwarded signed client goals.

The gateway and target each verify the signed bytes at their own trust
boundary.  After that, both paths converge here: the owning ontology
materializes the already-validated goal and enters the existing Prolog proof,
ACL, transaction, DTX, lifecycle, cursor, and outcome machinery.  This module
does not classify predicates or authorize goals.
""".

-export([verify_request/2, available/1,
         prepare_local/4, prepare_forwarded/5, execute/5]).

-type owner() ::
        {session, <<_:256>>, <<_:256>>} |
        {forwarder, <<_:256>>, pid(), <<_:256>>}.
-type prepared() ::
        {quod_client_goal:evidence(), term(), {agent, binary()}, owner()}.

-doc "Verify signature, network, signed target and deadline without routing.".
-spec verify_request(binary(), binary()) ->
          {ok, quod_client_goal:evidence()} | {error, term()}.
verify_request(RequestBytes, Signature) ->
    Started = erlang:monotonic_time(),
    case quod_client_goal:decode(RequestBytes) of
        {ok, #{agent_namespace := Ns,
               agent_genesis_anchor := Anchor}} ->
            Result = case network_identity() of
                         {ok, Network} ->
                             quod_client_goal:verify_for(
                               RequestBytes, Signature, Network, {Ns, Anchor},
                               quod_time:now_ms());
                         {error, _} = Error -> Error
                     end,
            ok = quod_metrics:observe_remote_operation_stage(
                   Ns, gateway_verification, metric_result(Result),
                   erlang:monotonic_time() - Started),
            Result;
        {error, _} = Error -> Error
    end.

metric_result({ok, _}) -> ok;
metric_result({error, _}) -> failed.

-doc "Require an exact ready local validator for the signed target.".
-spec available({binary(), <<_:256>>}) -> ok | {error, term()}.
available({Ns, <<_:256>> = Anchor}) when is_binary(Ns), byte_size(Ns) > 0 ->
    case {quod_reg:where({quod_prolog, Ns}),
          quod_simplex:genesis_hash(Ns)} of
        {Engine, Anchor} when is_pid(Engine) ->
            available_status(quod_simplex:status(Ns));
        {Engine, <<_:256>>} when is_pid(Engine) ->
            {error, wrong_target};
        _ ->
            {error, signed_target_unavailable}
    end;
available(_Target) ->
    {error, wrong_target}.

available_status(#{role := validator, syncing := false}) -> ok;
available_status(#{role := observer}) -> {error, signed_target_unavailable};
available_status(#{syncing := true}) -> {error, signed_target_unavailable};
available_status(Status) -> test_fixture_status(Status).

-ifdef(TEST).
%% Lightweight engine fixtures do not start consensus; production never uses
%% this clause because TEST is absent from release beams.
test_fixture_status(Status) when is_map(Status), map_size(Status) =:= 0 -> ok;
test_fixture_status(_Status) -> {error, signed_target_unavailable}.
-else.
test_fixture_status(_Status) -> {error, signed_target_unavailable}.
-endif.

-doc "Prepare a gateway-local request after browser session admission.".
-spec prepare_local(quod_client_goal:evidence(), term(), owner(),
                    none | <<_:256>>) ->
          {ok, prepared()} | {error, term()}.
prepare_local(Evidence, BrowserPeer, Owner, CursorBinding) ->
    prepare(Evidence, BrowserPeer, Owner, CursorBinding, local).

-doc "Independently verify and prepare a request from one authenticated node.".
-spec prepare_forwarded(binary(), binary(), <<_:256>>, pid(),
                        none | <<_:256>>) ->
          {ok, prepared()} | {error, term()}.
prepare_forwarded(RequestBytes, Signature, <<_:256>> = ForwarderKey,
                  RequestLink, CursorBinding) when is_pid(RequestLink) ->
    case verify_request(RequestBytes, Signature) of
        {ok, #{request := #{signing_public_key := SigningKey}} = Evidence} ->
            Owner = {forwarder, ForwarderKey, RequestLink, SigningKey},
            case request_available(Evidence) of
                ok ->
                    case quod_client_auth:admit_forwarded_goal(
                           SigningKey, ForwarderKey) of
                        ok ->
                            prepare_materialized(
                              Evidence, ForwarderKey, Owner, CursorBinding);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
prepare_forwarded(_RequestBytes, _Signature, _ForwarderKey,
                  _RequestLink, _CursorBinding) ->
    {error, invalid_request}.

prepare(Evidence, Peer, Owner, CursorBinding, local) ->
    case request_available(Evidence) of
        ok -> prepare_materialized(Evidence, Peer, Owner, CursorBinding);
        {error, _} = Error -> Error
    end.

request_available(#{request := #{agent_namespace := Ns,
                                 agent_genesis_anchor := Anchor}}) ->
    available({Ns, Anchor});
request_available(_Evidence) -> {error, invalid_request}.

prepare_materialized(
  #{goal_blob := GoalBlob,
    agent_ref_blob := AgentRef,
    request := #{mode := Mode, signing_public_key := SigningKey}} = Evidence,
  Peer, Owner, CursorBinding) ->
    case valid_mode_binding(Mode, CursorBinding) of
        false -> {error, invalid_request};
        true ->
            case quod_durable_term:decode_goal(GoalBlob) of
                {ok, OwnerGoal} ->
                    case quod_client_auth:materialize_request(
                           SigningKey, Peer, AgentRef, OwnerGoal) of
                        {ok, _MaterializedAgentRef, Goal} ->
                            {ok, {Evidence, Goal, {agent, AgentRef}, Owner}};
                        {error, _} = Error -> Error
                    end;
                {error, _} -> {error, invalid_goal}
            end
    end;
prepare_materialized(_Evidence, _Peer, _Owner, _CursorBinding) ->
    {error, invalid_request}.

valid_mode_binding(cursor, <<_:256>>) -> true;
valid_mode_binding(read, none) -> true;
valid_mode_binding(execute, none) -> true;
valid_mode_binding(_, _) -> false.

-doc "Enter the one existing proof/cursor path and normalize its result once.".
-spec execute(quod_client_goal:evidence(), term(), {agent, binary()}, owner(),
              none | <<_:256>>) ->
          {ok, quod_client_goal:evidence(),
           {normalized, quod_client_result:result()}} |
          {error, busy | rebuilding | client_cursor_unavailable |
                  operation_conflict}.
execute(#{request := #{mode := cursor}} = Evidence, Goal, Principal,
        Owner, <<_:256>> = CursorId) ->
    normalized(
      Evidence,
      quod_client_cursor:open(Owner, CursorId, Evidence, Goal, Principal));
execute(#{request := #{mode := read}} = Evidence, Goal, Principal,
        _Owner, none) ->
    normalized(Evidence, quod_prolog:execute_signed(Evidence, Goal, Principal));
execute(#{request := #{mode := execute}} = Evidence, Goal, Principal,
        _Owner, none) ->
    normalized(Evidence, quod_prolog:execute_signed(Evidence, Goal, Principal)).

normalized(Evidence, {ok, Evidence, Raw}) ->
    {ok, Evidence,
     {normalized, quod_client_result:normalize(Evidence, Raw)}};
%% These replies cannot carry durable custody. Keep that fact visible to the
%% forwarding boundary so another current validator can be tried; every other
%% engine result is normalized and terminal for this route.
normalized(_Evidence, {error, Reason} = Error)
  when Reason =:= busy; Reason =:= rebuilding;
       Reason =:= client_cursor_unavailable;
       Reason =:= operation_conflict ->
    Error;
normalized(Evidence, Raw) ->
    {ok, Evidence,
     {normalized, quod_client_result:normalize(Evidence, Raw)}}.

network_identity() ->
    case quod_ontology:network_identity() of
        {ok, <<_:256>> = Network} -> {ok, Network};
        _ -> {error, signed_goal_unavailable}
    end.
