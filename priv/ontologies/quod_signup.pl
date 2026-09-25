%% Open enrollment is ordinary ontology policy over signed agent goals.
%% Key-bound applicants have no administrator authority and no stored user
%% instance here. Completed humans live in their own ontologies. Receipts last
%% only until the new human's lobby transaction consumes them.
acl_sovereign(quod:signup).
open_signup.

instance_of(agent, signup(Key)) :- signup_key(Key).
agent_key(signup(Key), Key, active) :- open_signup, signup_key(Key).

signup_key(Key) :- binary_codes(Key, Bytes), length(Bytes, 32).

signup_principal(agent_instance_ref(Namespace, Anchor, signup(Key)), Key) :-
    current_ontology_identity(Namespace, Anchor),
    signup_key(Key).

can_invoke(Goal, Principal, _, _) :- signup_invocation(Goal, Principal).
can_invoke((current_ontology_identity(_, _), Goal), Principal, _, _) :-
    signup_invocation(Goal, Principal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

signup_invocation(signup(_, _, _), Principal) :- signup_principal(Principal, _).
signup_invocation(signup_status(_, _), Principal) :- signup_principal(Principal, _).
signup_invocation(ontology_creation_allowed(_, _, _), _).
signup_invocation(acknowledge_signup(Token, Reference), Reference) :-
    enrollment_receipt(_, Token, Reference).

signup(Token, Name, Reference) :-
    open_signup,
    signup_key(Token),
    current_principal(Principal),
    signup_principal(Principal, Key),
    transaction((
        \+ enrollment_receipt(Key, Token, _),
        signup_options(Principal, Name, Token, Options),
        quod:root::create_ontology(Name, Options, Anchor),
        Reference = agent_instance_ref(Name, Anchor, me),
        assertz(enrollment_receipt(Key, Token, Reference)))).

signup_status(Token, Reference) :-
    current_principal(Principal),
    signup_principal(Principal, Key),
    enrollment_receipt(Key, Token, Reference).

acknowledge_signup(Token, Reference) :-
    current_principal(Reference),
    retract(enrollment_receipt(_, Token, Reference)).

ontology_creation_allowed(Principal, Name, Options) :-
    open_signup,
    signup_options(Principal, Name, _, Options).

%% Both the action and root's independent permission proof use this exact
%% recipe. Founding pins the reviewed user source and lobby vocabulary.
signup_options(Principal, Name, Token,
    [source(Source),
     terms([instance_of(human_user, me), agent_key(me, Key, active),
            lobby_vocabulary(LobbyNamespace, LobbyAnchor),
            lobby_provisioning(me, pending(LobbyName)),
            signup_origin(Namespace, Anchor, Token)]),
     external_predicate_modules([quod_agent_predicates])]) :-
    signup_principal(Principal, Key),
    signup_key(Token),
    binary_codes(Name, NameBytes),
    append(NameBytes, [47,108,111,98,98,121], LobbyBytes),
    binary_codes(LobbyName, LobbyBytes),
    current_ontology_identity(Namespace, Anchor),
    user_template(Source),
    lobby_vocabulary(LobbyNamespace, LobbyAnchor).
