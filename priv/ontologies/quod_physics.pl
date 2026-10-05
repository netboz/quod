%% First mechanical profile: one optional world per containing ontology.
%% Space policy supplies every allowance and hosting/signing grant.
%% Distances are millimetres, time microseconds, density kg/m3.

agent_hosting_suspended(I) :- physics_space(_, disabled, I).

physics_projection(Node, Rows) :-
    findall(world(W, I, Epoch, Key, Generation, RunToken, Custody, Structure,
                  Limits, StepUs, Gravity, Bodies, Budget, baseline(Checkpoints, Joints)),
      (physics_space(W, enabled, I), agent_hosted(I, Node, Epoch, Key),
       physics_run(W, Generation, RunToken), physics_structure(W, Structure),
       physics_allowances(W, Limits, StepUs, Gravity, Budget),
       physics_custody(W, Custody),
       findall(C, physics_checkpoint(W, C), Checkpoints),
       findall(J, physics_joint(W, J), Joints),
       findall(body(Id, Rev, Kind, Position, HalfExtents, Density),
               physics_body(W, Id, Rev, Kind, Position, HalfExtents, Density), Bodies)), Rows).

physics_custody(W, Custody) :-
    findall(R, physics_request(W, R), Requests),
    (Requests = [] -> Custody = none ; Requests = [Custody]).

physics_actor(W) :-
    physics_space(W, enabled, I), current_ontology_identity(Ns, Anchor),
    current_principal(agent_instance_ref(Ns, Anchor, I)),
    agent_hosted(I, _, _, _).

%% The original signed activation is durable before submission. Its exact
%% request remains available after actor, runtime or host loss. This is domain
%% work in the existing ontology transaction lane, not a local outbox.
physics_store_request(W, Generation, Prior, Token, Bytes, Signature) :-
    transaction((physics_actor(W), physics_run(W, Generation, _),
        physics_custody(W, Prior), physics_previous_complete(Prior, Generation), agent_identifier(Token),
        physics_activation_request(W, Generation, Token, Bytes, Signature),
        \+ physics_cancelled_request(W, request(Token, Generation, Bytes, Signature)),
        (Prior = none -> true ; retract(physics_request(W, Prior))),
        assertz(physics_request(W, request(Token, Generation, Bytes, Signature))))).

physics_activate(W, Generation, Token) :-
    transaction((physics_actor(W), physics_run(W, Generation, Previous),
        physics_request(W, request(Token, Generation, Bytes, Signature)),
        current_signed_request(Bytes, Signature),
        retract(physics_run(W, Generation, Previous)), Next is Generation + 1,
        assertz(physics_run(W, Next, Token)))).

%% A pending request cannot be overwritten merely because its result is late.
physics_previous_complete(none, _).
physics_previous_complete(request(_, Previous, _, _), Generation) :- Generation > Previous.

%% An explicit policy action, never inferred from elapsed time. Removing this
%% exact custody invalidates the old activation's ordinary OCC read dependency.
%% The original bytes remain available; cancelled does not assert an operation
%% outcome for a request that may still be in flight.
can_cancel_physics_activation(_, _) :- fail.
physics_cancel_activation(W, Generation, Request) :-
    term_variables([W, Generation, Request], []),
    transaction((current_principal(Principal), can_cancel_physics_activation(W, Principal),
        physics_run(W, Generation, _),
        Request = request(_, Generation, _, _), physics_custody(W, Request),
        retract(physics_request(W, Request)),
        assertz(physics_cancelled_request(W, Request)))).

%% Durable domain status is derived from the same atomic transition, not a
%% separately maintained sent flag. Pending includes never-sent and uncertain.
physics_activation_status(W, Request, pending) :-
    physics_request(W, Request), Request = request(_, Generation, _, _),
    physics_run(W, Generation, _).
physics_activation_status(W, Request, activated) :-
    physics_request(W, Request), Request = request(Token, Previous, _, _),
    Generation is Previous + 1, physics_run(W, Generation, Token).
physics_activation_status(W, Request, cancelled) :- physics_cancelled_request(W, Request).
