%% Open enrollment is ordinary ontology policy over signed agent goals.
%% Key-bound applicants have no administrator authority and no stored user
%% instance here. Completed humans live in their own ontologies. Receipts last
%% only until the new human's lobby transaction consumes them.
acl_sovereign(quod:signup).
open_signup.

instance_of(agent, signup(Key)) :- signup_key(Key).
agent_key(signup(Key), Key, active) :- open_signup, signup_key(Key).

signup_key(Key) :- binary_codes(Key, Bytes), length(Bytes, 32).

%% Names are derived by policy, including when root is called directly.
%% URL-safe base64 without padding preserves the browser's namespace spelling.
signup_name(Token, Name) :-
    binary_codes(Token, Bytes), length(Bytes, 32),
    signup_token_codes(Bytes, Encoded),
    append([104,117,109,97,110,58], Encoded, Codes),
    binary_codes(Name, Codes).

signup_token_codes([A,B], [X,Y,Z]) :-
    I is A // 4, J is (A mod 4) * 16 + B // 16, K is (B mod 16) * 4,
    signup_digit(I, X), signup_digit(J, Y), signup_digit(K, Z).
signup_token_codes([A,B,C|Rest], [W,X,Y,Z|Codes]) :-
    I is A // 4, J is (A mod 4) * 16 + B // 16,
    K is (B mod 16) * 4 + C // 64, L is C mod 64,
    signup_digit(I, W), signup_digit(J, X),
    signup_digit(K, Y), signup_digit(L, Z),
    signup_token_codes(Rest, Codes).

signup_digit(N, Code) :-
    (N < 26 -> Code is N + 65
    ; N < 52 -> Code is N + 71
    ; N < 62 -> Code is N - 4
    ; N = 62 -> Code = 45
    ; Code = 95).

signup_lobby_name(Name, LobbyName) :-
    binary_codes(Name, NameBytes),
    append(NameBytes, [47,108,111,98,98,121], LobbyBytes),
    binary_codes(LobbyName, LobbyBytes).

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
signup_invocation(ontology_hosting_allowed(Principal, _, _, _, _), Principal).
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
        assertz(enrollment_receipt(Key, Token, Reference)),
        signup_host(Node),
        Node = agent_instance_ref(NodeNamespace, _, _),
        NodeNamespace::request_ontology_hosting(Principal, Node, Name, Anchor, discoverable))).

%% The node explicitly delegates this policy. Only the exact enrollment and
%% its linked personal lobby qualify; consuming the receipt ends the grant.
ontology_hosting_allowed(Principal, Node, Name, Anchor, discoverable) :-
    current_principal(Principal),
    signup_host(Node),
    signup_principal(Principal, Key),
    enrollment_receipt(Key, _, agent_instance_ref(Name, Anchor, me)).
ontology_hosting_allowed(Owner, Node, Name, Anchor, discoverable) :-
    current_principal(Owner),
    signup_host(Node),
    enrollment_receipt(_, _, Owner),
    Owner = agent_instance_ref(UserNamespace, UserAnchor, me),
    signup_lobby_name(UserNamespace, Name),
    UserNamespace::(current_ontology_identity(UserNamespace, UserAnchor),
                    lobby_reference(ontology_ref(Name, Anchor))).

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
            hosting_node(Node),
            signup_origin(Namespace, Anchor, Token)]),
     external_predicate_modules([quod_agent_predicates])]) :-
    signup_principal(Principal, Key),
    signup_name(Token, Name),
    signup_lobby_name(Name, LobbyName),
    current_ontology_identity(Namespace, Anchor),
    user_template(Source),
    signup_host(Node),
    lobby_vocabulary(LobbyNamespace, LobbyAnchor).
