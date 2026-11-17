%% Open enrollment is ordinary ontology policy over signed agent goals.
%% Key-bound applicants have no administrator authority and no stored user
%% instance here. Completed humans live in their own ontologies. Receipts last
%% only until the new human's setup transaction consumes them.
acl_sovereign(quod:user).
isa(human_user, agent).
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

signup_principal(agent_instance_ref(Namespace, Anchor, signup(Key)), Key) :-
    current_ontology_identity(Namespace, Anchor),
    signup_key(Key).

can_invoke(Goal, Principal, _, _) :- signup_invocation(Goal, Principal).
can_invoke((current_ontology_identity(_, _), Goal), Principal, _, _) :-
    signup_invocation(Goal, Principal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

signup_invocation(signup(_, _, _), Principal) :- signup_principal(Principal, _).
signup_invocation(signup_status(_, _), Principal) :- signup_principal(Principal, _).
signup_invocation(ontology_creation_allowed(_, _, _), _).
signup_invocation(isa(_, _), _).
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

%% Only the unconsumed exact account allocation grants its hosting intention.
ontology_hosting_allowed(Principal, Node, Name, Anchor, discoverable) :-
    current_principal(Principal), signup_host(Node),
    signup_principal(Principal, Key),
    enrollment_receipt(Key, _, agent_instance_ref(Name, Anchor, me)).

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

%% Policy selects exact ordered packaged paths and SHA-256 source hashes.
%% Existing lifecycle preparation reads, checks and compiles each buffer once.
signup_options(Principal, Name, Token, Options) :-
    current_ontology_identity(Namespace, Anchor), signup_host(Node),
    findall(Directory, user_source_directory(Directory), [Directory]),
    binary_codes(Directory, DirectoryBytes),
    findall(source_file(Path, Hash),
        (user_source_component(File, Hash), binary_codes(File, FileBytes),
         append(DirectoryBytes, [47 | FileBytes], PathBytes), binary_codes(Path, PathBytes)), Sources),
    findall(File, user_source_component(File, _),
        [<<"user_instance.pl">>, <<"agent_instance.pl">>, <<"quod_space.pl">>, <<"gui_instance.pl">>]),
    findall(pins(AClass, G, C, S, Digest),
        (agent_vocabulary(<<"quod:agent">>, AClass),
         gui_vocabulary(<<"quod:gui">>, G),
         controllers_vocabulary(<<"quod:controllers">>, C),
         space_vocabulary(<<"quod:space">>, S), space_source_digest(Digest)),
        [pins(AClass, G, C, S, Digest)]),
    <<"quod:space">>::(current_ontology_identity(<<"quod:space">>, S), space_template_hash(Digest)),
    user_source_component(<<"quod_space.pl">>, Digest),
    append(Sources,
        [terms([user_namespace(Name), instance_of(human_user, me), agent_key(me, Key, active),
                agent_vocabulary(<<"quod:agent">>, AClass),
                gui_vocabulary(<<"quod:gui">>, G),
                measure_vocabulary(<<"quod:gui">>, G),
                rendering_vocabulary(<<"quod:gui">>, G),
                modelling_vocabulary(<<"quod:gui">>, G),
                controllers_vocabulary(<<"quod:controllers">>, C),
                space_vocabulary(<<"quod:space">>, S), space_source_digest(Digest),
                account_setup(me, pending(account)), hosting_node(Node),
                signup_origin(Namespace, Anchor, Token)]),
         external_predicate_modules([quod_agent_predicates])], Options),
    signup_principal(Principal, Key), signup_name(Token, Name).
