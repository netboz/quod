%% Open enrollment is ordinary ontology policy over signed agent goals.
%% Key-bound applicants have no administrator authority and no stored user
%% instance here. Completed humans live in their own ontologies. Receipts last
%% only until the new human's setup transaction consumes them.
acl_sovereign(quod:user).
isa(human_user, quod:agent:agent).
isa(personal_agent, quod:agent:agent).
open_signup.

instance_of(quod:agent:agent, signup(Key)) :- signup_key(Key).
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

can_invoke(Goal, agent_instance_ref(Ns, _, signup(Key)), _, Ns) :-
    signup_key(Key), member(Request, [signup(_, _, _), signup_status(_, _)]),
    member(Goal, [Request, (current_ontology_identity(Ns, _), Request)]).
can_invoke(Goal, Principal, _, _) :- signup_invocation(Goal, Principal).
can_invoke((current_ontology_identity(_, _), Goal), Principal, _, _) :-
    signup_invocation(Goal, Principal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

signup_invocation(ontology_creation_allowed(_, _, _), _).
signup_invocation(isa(_, _), _).
signup_invocation(Goal, _) :- public_source_query(Goal).
signup_invocation(account_setup_state(_), _).
signup_invocation(controller_preferences_view(_, _), _).
signup_invocation(controller_preferences_set(_, _, _, _, _), _).
signup_invocation(controller_settings_save(_, _, _, _, _, _, _), _).
signup_invocation(shown_as(_, _, _), _).
signup_invocation(show_as(_, _, _), _).
signup_invocation(account_setup_preparation(_), _).
signup_invocation(account_navigation(_), _).
signup_invocation(account_navigation(_, _), _).
signup_invocation(class_eidolon(_, _, _, _), _).
signup_invocation(eidolon(_, _, _), _).
signup_invocation(class_permission(_, _, _), _).
signup_invocation(class_requirement(_, _, _), _).
signup_invocation('$quod_constructor_metadata'(_, _, _), _).
signup_invocation(have_attribute(_, _, _), _).
signup_invocation(have_attribute(_, _, _, _), _).
signup_invocation(gui_definition(_, _, _, _, _, _), _).
signup_invocation(gui_initial_values(_, _, _, _), _).
signup_invocation(gui_bind_values(_, _, _, _, _), _).
signup_invocation(gui_form_caption(_, _, _, _, _), _).
signup_invocation(personal_agent(_, _), _).
signup_invocation(personal_agent_owner(_), _).
signup_invocation(personal_agent_preparation(_), _).
signup_invocation(personal_instruction_accept(_, _), _).
signup_invocation(personal_instruction_lookup(_, _, _), _).
signup_invocation(personal_instruction_retained(_, _), _).
signup_invocation(personal_instructions(_), _).
signup_invocation(retain_personal_instruction(_, _, _), _).
signup_invocation(can_sign_agent_request(_, _, _), _).
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
    Options = [terms(Terms), external_predicate_modules([quod_agent_predicates])],
    current_ontology_identity(Namespace, Anchor),
    member(signup_origin(Namespace, Anchor, Token), Terms),
    signup_options(Principal, Name, Token, Expected),
    variant_digest(Expected, Digest), variant_digest(Options, Digest).

%% Signup writes the human's facts, local ACL and hosted reaction as terms.
%% Shared behavior stays at its class owner and enters through ordinary scopes.
signup_options(Principal, Name, Token,
        [terms(Terms), external_predicate_modules([quod_agent_predicates])]) :-
    current_ontology_identity(Namespace, Anchor), signup_host(Node),
    findall(pins(AClass, G, C, S),
        (agent_vocabulary(<<"quod:agent">>, AClass),
         gui_vocabulary(<<"quod:gui">>, G),
         controllers_vocabulary(<<"quod:controllers">>, C),
         space_vocabulary(<<"quod:space">>, S)),
        [pins(AClass, G, C, S)]),
    findall(Clause, account_policy_clause(Clause), Policy),
    append([user_namespace(Name), instance_of(quod:user:human_user, me),
            instance_of(quod:user:personal_agent, personal), agent_key(me, Key, active),
            agent_vocabulary(<<"quod:agent">>, AClass),
            gui_vocabulary(<<"quod:gui">>, G),
            measure_vocabulary(<<"quod:gui">>, G),
            rendering_vocabulary(<<"quod:gui">>, G),
            modelling_vocabulary(<<"quod:gui">>, G),
            controllers_vocabulary(<<"quod:controllers">>, C),
            space_vocabulary(<<"quod:space">>, S),
            account_setup(me, pending(account)), hosting_node(Node),
            signup_origin(Namespace, Anchor, Token),
            instance_of(quod:gui:hud, my_hud), hud_allowance(my_hud, 12),
            gui_pending_allowance(me, 8),
            entity_scene(personal, playing, hidden), entity_scene(personal, edition, hidden)],
           Policy, Terms),
    signup_principal(Principal, Key), signup_name(Token, Name).

%% The user's ontology owns these editable ACL clauses, its reaction and
%% the two local hosting derivations. No class behavior is installed there.
account_policy_clause((can_invoke(_, agent_instance_ref(Namespace, _, Instance), _, Namespace) :-
    instance_of(quod:user:human_user, Instance))).

account_policy_clause((human_user_owner(agent_instance_ref(Ns, Anchor, Instance)) :-
    current_ontology_identity(Ns, Anchor), instance_of(quod:user:human_user, Instance))).

account_policy_clause((ontology_source_mode(editable) :- current_principal(Owner), human_user_owner(Owner))).

account_policy_clause((can_prepare_agent_key(Owner, personal, none, 0, Node) :-
    Owner = agent_instance_ref(_, _, Human), instance_of(quod:user:human_user, Human), hosting_node(Node),
    \+ agent_host(personal, _, _, _), \+ agent_key(personal, _, _))).

account_policy_clause((can_assign_agent_host(Owner, personal, none, 0, Node, _) :-
    Owner = agent_instance_ref(_, _, Human), instance_of(quod:user:human_user, Human), hosting_node(Node))).

account_policy_clause((can_invoke(_, agent_instance_ref(Ns, _, personal), [Owner|_], Ns) :-
    instance_of(quod:user:personal_agent, personal),
    member(Owner, [<<"quod:space">>, <<"quod:gui">>, <<"quod:agent">>, <<"quod:user">>]))).

account_policy_clause((can_invoke(_, Node, [<<"quod:user">>|_], _) :- hosting_node(Node))).

account_policy_clause((can_invoke(<<"quod:user">>::retain_personal_instruction(_, _, _),
           agent_instance_ref(Ns, _, personal), _, Ns))).

account_policy_clause((can_invoke((agent_hosted(personal, Node, Epoch, Key), sign_agent_request(_, _)), Node, _, _) :-
    hosting_node(Node), agent_hosted(personal, Node, Epoch, Key))).

account_policy_clause((can_invoke(Goal, Actor, _, Ns) :-
    Actor = agent_instance_ref(Ns, Anchor, personal),
    variant_digest(Goal, Digest),
    personal_instruction(Owner, _, authority(UKey, Key, Digest), _, _, _, _),
    Owner = agent_instance_ref(Ns, Anchor, Human),
    instance_of(quod:user:human_user, Human), agent_key(Human, UKey, active),
    hosting_node(Node), agent_hosted(personal, Node, _, Key),
    \+ agent_hosting_suspended(personal))).

account_policy_clause((can_invoke(Goal, Principal, _, Ns) :-
    instance_of(quod:user:human_user, Human), gui_receiver_policy(Human, Principal),
    Read = <<"quod:gui">>::gui_receiver_for(agent_instance_ref(Ns, _, Human), _),
    member(Goal, [Read, (current_ontology_identity(Ns, _), Read)]))).

account_policy_clause((can_invoke(_, Principal, [<<"quod:gui">>|_], Ns) :-
    instance_of(quod:user:human_user, Human),
    (Principal = agent_instance_ref(Ns, _, Human); gui_receiver_policy(Human, Principal)))).

account_policy_clause((can_invoke(_, agent_instance_ref(ActorNs, ActorAnchor, _), [<<"quod:gui">>|_], _) :-
    gui_pending(_, question_ref(ActorNs, ActorAnchor, _)))).

account_policy_clause((can_invoke((current_ontology_identity(Ns, _), (instance_of(quod:gui:hud, Id), Goal)),
           Principal, [<<"quod:gui">>|_], Ns) :-
    instance_of(quod:gui:hud, Id),
    member(Goal, [
        (findall(H, instance_of(quod:user:human_user, H), [_]),
         findall(D, space_assignment_state(personal, _, D), _)),
        (instance_of(quod:user:human_user, Human), gui_receiver_policy(Human, Principal)),
        (\+ hud_contribution(Id, Subject, Choice, _),
         assertz(hud_contribution(Id, Subject, Choice, Principal))),
        (\+ hud_offered(Id, _, Subject, Choice), \+ hud_contribution(Id, Subject, Choice, _),
         assertz(hud_offered(Id, Principal, Subject, Choice))),
        hud_contribution(Id, Subject, Choice, Principal),
        retract(hud_contribution(Id, Subject, Choice, Principal)),
        retract(hud_offered(Id, Principal, Subject, Choice))]))).

account_policy_clause((can_invoke(_, Caller, [<<"quod:gui">>|_], Ns) :-
    gui_question(_, _, Human, Actor, _, _),
    (Caller = Human; Caller = agent_instance_ref(Ns, _, Actor)))).

account_policy_clause((can_invoke(_, Node, [Owner|_], _) :-
    member(Owner, [<<"quod:gui">>, <<"quod:agent">>]),
    agent_host(Actor, Node, _, _), agent_hosted(Actor, Node, _, _))).

account_policy_clause((can_invoke(_, Caller, [<<"quod:gui">>|_], _) :-
    gui_question_policy(_, Human, Actor), (Caller = Human; Caller = Actor))).

account_policy_clause((can_invoke(_, Caller, [<<"quod:gui">>|_], Ns) :-
    gui_responder_policy(Instance, _, Human),
    (Caller = Human; Caller = agent_instance_ref(Ns, _, Instance)))).

account_policy_clause((can_invoke(<<"quod:gui">>::gui_open(form_ref(Ns, _, Form), _), Caller, _, Ns) :-
    gui_question_policy(Form, Human, Actor), (Caller = Human; Caller = Actor))).

account_policy_clause((can_invoke(<<"quod:gui">>::gui_complete(question_ref(Ns, Anchor, Q)),
           agent_instance_ref(Ns, Anchor, Actor), _, Ns) :-
    gui_question(Q, _, _, Actor, _, submitted(_, _, _, _)))).

account_policy_clause((can_invoke(Goal, Caller, _, Ns) :-
    Read = <<"quod:gui">>::gui_native_handler(agent_instance_ref(Ns, _, Instance), Source, Human, _, _),
    member(Goal, [Read, (current_ontology_identity(Ns, _), Read)]),
    gui_responder_policy(Instance, Source, Human),
    (Caller = Human; Caller = agent_instance_ref(Ns, _, Instance)))).

account_policy_clause((can_invoke(Goal, Human, _, Ns) :-
    gui_question(Q, _, Human, _, _, _), Reference = question_ref(Ns, _, Q),
    member(Query, [gui_submit(Reference, _, _, _), gui_cancel(Reference),
                   gui_question_status(Reference, _), gui_question_view(Reference, _, _, _),
                   gui_question_form(Reference, _)]),
    Read = <<"quod:gui">>::Query,
    member(Goal, [Read, (current_ontology_identity(Ns, _), Read)]))).

account_policy_clause((can_invoke(Goal, Node, _, Ns) :-
    Typed = agent_goal_v1(_, agent_instance_ref(Ns, _, Actor), _, Key, _, _, execute, 3, _),
    agent_hosted(Actor, Node, Epoch, Key),
    Read = (agent_hosted(Actor, Node, Epoch, Key), sign_agent_request(Typed, _)),
    member(Goal, [Read, (current_ontology_identity(Ns, _), Read)]))).

account_policy_clause((react_on(assert(gui_question(Q, Source, Human, Actor, Revision, Submitted)),
         <<"quod:gui">>::gui_complete(question_ref(Ns, Anchor, Q))) :-
    Submitted = submitted(_, _, _, Bytes),
    me(agent_instance_ref(Ns, Anchor, Actor)),
    gui_question(Q, Source, Human, Actor, Revision, Submitted),
    use_agent_request(Bytes))).

account_policy_clause((agent_hosted(Instance, NodeRef, Epoch, PublicKey) :-
    findall(host(N,E,K),agent_host(Instance,N,E,K),[host(NodeRef,Epoch,PublicKey)]),
    findall(K,agent_key(Instance,K,active),[PublicKey]))).

account_policy_clause((agent_hosting_projection(Requested, Node, Scope, Hosts) :-
    (Requested = agent(Instance) -> Scope = keys([Instance]), Instances = [Instance]
    ; Requested = all, Scope = all,
      findall(I,agent_host(I,Node,_,_),Raw),sort(Raw,Instances)),
    (Node \= none ->
        findall(host(I,Node,E,K),
            (member(I,Instances),agent_hosted(I,Node,E,K),\+ agent_hosting_suspended(I)),Hosts)
    ; Hosts = []))).

%% Class behavior reads the exact storing ontology. Its ACL still governs
%% every callback, including the native signing call bound to that identity.
human_user_owner(agent_instance_ref(Ns, Anchor, Human)) :-
    in_ontology(Ns, Anchor, instance_of(quod:user:human_user, Human)).

personal_agent_owner(Owner) :-
    current_principal(Principal), Principal = agent_instance_ref(Ns, Anchor, Instance),
    in_ontology(Ns, Anchor,
        ((instance_of(quod:user:human_user, Instance)
         ; instance_of(quod:user:personal_agent, Instance)),
         findall(Human, instance_of(quod:user:human_user, Human), [Human]))),
    Owner = agent_instance_ref(Ns, Anchor, Human).

personal_agent(Agent, Key) :-
    personal_agent_owner(agent_instance_ref(Ns, Anchor, _)),
    Agent = agent_instance_ref(Ns, Anchor, personal),
    in_ontology(Ns, Anchor, (hosting_node(Node), agent_hosted(personal, Node, _, Key))).

personal_agent_preparation(Preparation) :-
    current_principal(Owner), human_user_owner(Owner),
    Owner = agent_instance_ref(Ns, Anchor, _),
    in_ontology(Ns, Anchor,
        (hosting_node(Node),
         (agent_hosted(personal, Node, _, _) -> Preparation = ready
         ; prepare_agent_key_custody(agent_instance_ref(Ns, Anchor, personal), none, 0, Node, Key),
           Preparation = prepared(Node, Key)))).

personal_instruction_accept(Bytes, Signature) :-
    current_principal(Owner),
    agent_request_bytes(Typed, Bytes),
    can_instruct_personal_agent(Owner, Typed),
    Typed = agent_goal_v1(_, agent_instance_ref(Ns, Anchor, _), _, _, _, Expiry, _, _, _),
    current_request_expiry(Deadline), Expiry =< Deadline,
    in_ontology(Ns, Anchor, sign_agent_request(Typed, Signature)).

can_instruct_personal_agent(Owner,
    agent_goal_v1(_, agent_instance_ref(Ns, Anchor, personal), _, Key, _, _, execute, 3, _)) :-
    Owner = agent_instance_ref(Ns, Anchor, Human),
    in_ontology(Ns, Anchor,
        (instance_of(quod:user:human_user, Human), hosting_node(Node),
         agent_hosted(personal, Node, _, Key), \+ agent_hosting_suspended(personal))).

%% Original human bytes and current committed keys both supply authority.
personal_instruction_authorized(UBytes, USignature, Typed, Owner, UKey) :-
    signed_agent_request(UBytes, USignature,
        agent_goal_v1(Network, Owner, _, UKey, _, Expiry, read, 3, Text)),
    Owner = agent_instance_ref(Ns, Anchor, Human),
    in_ontology(Ns, Anchor,
        (instance_of(quod:user:human_user, Human), agent_key(Human, UKey, active))),
    '$quod_program_source'([<<"quod:user">>::personal_instruction_accept(Bytes, _)], Text),
    agent_request_bytes(Typed, Bytes),
    Typed = agent_goal_v1(Network, _, _, _, _, TargetExpiry, execute, 3, _),
    TargetExpiry =< Expiry,
    can_instruct_personal_agent(Owner, Typed).

can_sign_agent_request(Owner, Node, Typed) :-
    Owner = agent_instance_ref(Ns, Anchor, _),
    in_ontology(Ns, Anchor, hosting_node(Node)),
    can_instruct_personal_agent(Owner, Typed).
can_sign_agent_request(Node, Node, Typed) :-
    Typed = agent_goal_v1(_, Actor, _, Key, _, _, _, _, _),
    Actor = agent_instance_ref(Ns, Anchor, personal),
    in_ontology(Ns, Anchor, (hosting_node(Node), agent_hosted(personal, Node, _, Key))),
    can_request_agent_signature(Node, personal, Typed).

can_request_agent_signature(_Node, personal,
    agent_goal_v1(Network, Actor, _, Key, _, Expiry, execute, 3, Text)) :-
    '$quod_program_source'([<<"quod:user">>::retain_personal_instruction(UBytes, USignature, Signature)], Text),
    personal_instruction_authorized(UBytes, USignature, Requested, _, _),
    Requested = agent_goal_v1(Network, Actor, _, Key, _, Expiry, execute, 3, _),
    agent_request_bytes(Requested, Bytes),
    signed_agent_request(Bytes, Signature, Requested).

%% The association is stored with the actor; outcomes stay in their existing
%% transaction owner. Restoring this row never dispatches its request.
retain_personal_instruction(UBytes, USignature, Signature) :-
    personal_instruction_authorized(UBytes, USignature, Typed, Owner, UKey),
    agent_request_bytes(Typed, Bytes),
    signed_agent_request(Bytes, Signature, Typed),
    Typed = agent_goal_v1(_, Actor, _, Key, Id, _, execute, 3, Text),
    '$quod_program_source'([Requested], Text), variant_digest(Requested, Digest),
    current_principal(Actor), Actor = agent_instance_ref(Ns, Anchor, personal),
    in_ontology(Ns, Anchor,
        transaction((\+ personal_instruction(_, Id, _, _, _, _, _),
                     assertz(personal_instruction(Owner, Id, authority(UKey, Key, Digest),
                                                  UBytes, USignature, Bytes, Signature))))).

personal_instruction_retained(Bytes, Retained) :-
    agent_request_bytes(agent_goal_v1(_, agent_instance_ref(Ns, Anchor, _), _, _, Id, _, execute, 3, _), Bytes),
    in_ontology(Ns, Anchor,
        (personal_instruction(_, Id, _, _, _, _, _) -> Retained = true; Retained = false)).

personal_instruction_lookup(Id, Bytes, Signature) :-
    current_principal(Owner), human_user_owner(Owner),
    Owner = agent_instance_ref(Ns, Anchor, _),
    in_ontology(Ns, Anchor,
        (personal_instruction(Owner, Id, _, _, _, Bytes, Signature) -> true
        ; Bytes = none, Signature = none)).

personal_instructions(Instructions) :-
    current_principal(Owner), human_user_owner(Owner),
    Owner = agent_instance_ref(Ns, Anchor, _),
    in_ontology(Ns, Anchor,
        findall(instruction(Id, Bytes, Signature),
                personal_instruction(Owner, Id, _, _, _, Bytes, Signature), Instructions)).

account_setup_state(State) :-
    current_principal(Owner), human_user_owner(Owner),
    Owner = agent_instance_ref(Ns, Anchor, Human),
    in_ontology(Ns, Anchor,
        (account_setup(Human, pending(account)) -> State = pending(ontology_ref(Ns, Anchor))
        ; account_setup(Human, complete(State)))).

account_navigation(Space, [playing, edition]) :-
    account_navigation(navigation(_, placed(Space, _), [playing, edition])).
account_navigation(navigation(Revision, Location, [playing, edition])) :-
    current_principal(Owner), human_user_owner(Owner),
    Owner = agent_instance_ref(Ns, Anchor, Human),
    in_ontology(Ns, Anchor, account_setup(Human, complete(_))),
    quod:space::space_assignment(entity_ref(Ns, Anchor, personal), Revision, _),
    quod:space::space_location(entity_ref(Ns, Anchor, personal), Location).

account_setup_preparation(Preparation) :-
    current_principal(Owner), human_user_owner(Owner),
    Owner = agent_instance_ref(Ns, Anchor, Human),
    (in_ontology(Ns, Anchor, account_setup(Human, complete(Result))) -> Preparation = complete(Result)
    ; in_ontology(Ns, Anchor, account_setup(Human, pending(account))),
      quod:space::space_location(entity_ref(Ns, Anchor, Human), unplaced),
      quod:space::space_location(entity_ref(Ns, Anchor, personal), unplaced),
      in_ontology(Ns, Anchor,
        (hosting_node(Node),
         prepare_agent_key_custody(agent_instance_ref(Ns, Anchor, personal), none, 0, Node, Key, Receipt))),
      Preparation = prepared(ontology_ref(Ns, Anchor), Node, prepared_key(Key, Receipt))).

class_eidolon(personal_agent, menu, default, recipe(Ns, A, personal_menu)) :- current_ontology_identity(Ns, A).
eidolon(personal_menu, subject(ontology_ref(Ns, A), personal), menu(Tree)) :-
    findall(Item, personal_menu_destination(ontology_ref(Ns, A), Item), Known),
    in_ontology(Ns, A,
        (gui_menu_source(quod:space:space, menu_source(_, Create)),
         findall(Item, (instance_of(quod:user:human_user, Human),
             gui_menu_source(Human, menu_source(_, Own)), member(Item, Own)), Choices))),
    (quod:space::space_location(entity_ref(Ns, A, personal), unplaced) ->
        Title = <<"You are nowhere yet">>; Title = <<"You">>),
    menu_icon(go_to, KnownIcon), menu_icon(create_here, CreateIcon), menu_icon(me, MeIcon),
    menu_vocabulary(Gui, GuiAnchor),
    in_ontology(Gui, GuiAnchor, menu_tree(menu(Title, <<"">>, [],
        [group(<<"Enter a known space">>, [slot(1), image(KnownIcon)], [operation(instance)], Known),
         group(<<"Create a space">>, [slot(3), image(CreateIcon)], [operation(class)], Create),
         group(<<"Your choices">>, [slot(5), image(MeIcon)], [operation(instance),playing,edition,prolog,inspection,workspace], Choices)]), Tree)).
personal_menu_destination(ontology_ref(Ns, A), item(T, Label, Help, Availability, Options)) :-
    quod:space::space_instance(entity_ref(Ns, A, Space), space), Space \= ontology_ref(_, _),
    in_ontology(Ns, A, gui_menu_source(Space, menu_source(Name, Items))),
    member(item(T, Offered, Help, Availability, Options), Items),
    T = choice(_, eidolon(operation(instance), enter, _)),
    (binary(Name), Name \== <<"">> -> Label = Name; Label = Offered).

%% Setup receives custody prepared by the existing signed read. Its form
%% definition reads committed data only; submission verifies the receipt.
class_permission(human_user, setup, allow).
class_eidolon(human_user, operation(instance), setup, recipe(Ns, A, setup)) :- current_ontology_identity(Ns, A).
eidolon(setup, subject(Storage, instance(Human)), operation(setup(Storage, Node))) :-
    Storage = ontology_ref(Ns, Anchor),
    current_principal(agent_instance_ref(Ns, Anchor, Human)),
    in_ontology(Ns, Anchor,
        (instance_of(quod:user:human_user, Human), account_setup(Human, pending(account)), hosting_node(Node))).
instance_of(quod:gui:form, setup(_, _)).
instance_of(quod:gui:text_box, setup_key).
instance_of(quod:gui:text_box, setup_receipt).
instance_of(quod:gui:button, setup_submit).
attribute(setup(_, _), label, <<"Create your starting space">>).
attribute(setup_key, label, <<"Prepared key">>).
attribute(setup_receipt, label, <<"Preparation receipt">>).
attribute(setup_submit, label, <<"Create">>).
gui_children(setup(_, _), [setup_key, setup_receipt, setup_submit]).
gui_form(setup(Storage, Node), [field(setup_key, Key), field(setup_receipt, Receipt)],
    submit(setup_submit,
        (current_ontology_identity(Ns, Anchor), current_principal(Owner),
         instance_of(quod:user:human_user, Human), account_setup(Human, pending(account)), hosting_node(Node),
         quod:space::space_location(entity_ref(Ns, Anchor, Human), unplaced),
         quod:space::space_location(entity_ref(Ns, Anchor, personal), unplaced),
         prepared_agent_key_custody(Agent, none, 0, Node, Key, Receipt), ResultKey = Key,
         transaction((
            quod:agent::goal(agent_hosted(Agent, Node, 1, Key)),
            with_build_plan([attribute(owner, Owner)], assert(instance_of(quod:space:space, Space))),
            quod:space::goal(inside(entity_ref(Ns, Anchor, Space), entity_ref(Ns, Anchor, personal), transform(0,0,0,0,0,0))),
            retract(account_setup(Human, pending(account))), assertz(account_setup(Human, complete(Result))),
            signup_origin(Signup, SignupAnchor, Token),
            in_ontology(Signup, SignupAnchor, acknowledge_signup(Token, Owner)),
            retract(signup_origin(Signup, SignupAnchor, Token))))),
        operation(setup, [result(setup, Result)]))) :-
    Storage = ontology_ref(Ns, Anchor),
    current_principal(Owner), Owner = agent_instance_ref(Ns, Anchor, Human),
    Agent = agent_instance_ref(Ns, Anchor, personal),
    in_ontology(Ns, Anchor,
        (instance_of(quod:user:human_user, Human), account_setup(Human, pending(account)), hosting_node(Node),
         signup_origin(Signup, SignupAnchor, Token),
         unique_solution(agent_vocabulary(<<"quod:agent">>, AClass)),
         unique_solution(gui_vocabulary(<<"quod:gui">>, Gui)),
         unique_solution(controllers_vocabulary(<<"quod:controllers">>, Controllers)),
         unique_solution(space_vocabulary(<<"quod:space">>, Spaces)))),
    Result = account(Owner, Agent, entity_ref(Ns, Anchor, Space), Storage, ResultKey, pins(AClass, Gui, Controllers, Spaces)).

%% Private human preferences. Connection, pose and button observations never
%% enter this source. Compose the existing GUI form and operation owners.
have_attribute(human_user,controller_preferences,controller_preferences).
class_permission(human_user,configure_controller,allow).
controller_read(Human) :-
    Human = entity_ref(Ns,A,Instance),
    current_principal(Owner), Owner = agent_instance_ref(Ns,A,Instance), human_user_owner(Owner).
controller_preferences_current(Human,Revision,Settings) :-
    Human = entity_ref(Ns,A,Instance),
    in_ontology(Ns,A,(instance_of(quod:user:human_user,Instance),
        findall(P,attribute(Instance,controller_preferences,P),Rows))),
    (Rows = [] -> Revision = 0, controller_vocabulary(controller_default(Settings))
    ; Rows = [preferences(Revision,Settings)],integer(Revision),Revision > 0).
controller_vocabulary(Goal) :-
    controllers_vocabulary(Ns,A),Ns::(current_ontology_identity(Ns,A),Goal).
%% Invalid single-row settings remain explicitly repairable. Their exact value
%% is fenced too; a malformed or duplicate row has no unambiguous revision.
controller_preferences_basis(Settings,Digest,State) :-
    (controller_vocabulary(controller_configuration(Settings,Mapping)) ->
      State = valid(Mapping),term_digest(Mapping,Digest)
    ; State = invalid,term_digest(invalid_controller_settings(Settings),Digest)).
controller_preferences_view(Human,controller_view(Revision,Digest,Mapping)) :-
    controller_read(Human),
    controller_preferences_current(Human,Revision,Settings),
    controller_preferences_basis(Settings,Digest,State),
    (State = valid(Mapping) -> true; State = invalid,Mapping = invalid_settings).

controller_preferences_set(Human,Expected,ExpectedDigest,Settings,Next) :-
    term_variables([Human,Expected,ExpectedDigest,Settings],[]),
    Human = entity_ref(Ns,A,Instance),
    personal_agent_owner(agent_instance_ref(Ns,A,Instance)),
    in_ontology(Ns,A,operation_authorized(instance(Instance),configure_controller(Expected,ExpectedDigest,Settings))),
    transaction((controller_preferences_current(Human,Expected,Previous),
      controller_preferences_basis(Previous,ExpectedDigest,_),
      controller_vocabulary(controller_configuration(Settings,_)),
      Next is Expected + 1,
      in_ontology(Ns,A,
        ((Expected = 0 -> true; retract(attribute(Instance,controller_preferences,preferences(Expected,Previous)))),
         assertz(attribute(Instance,controller_preferences,preferences(Next,Settings))))))).

%% What a human sees of a thing, for one purpose: one fact on the human, in
%% their own ontology, never on the thing. Default removes it. Only the human
%% or their personal agent reads or changes it.
shown_as(Thing, Purpose, Name) :-
    personal_agent_owner(agent_instance_ref(Ns,A,Human)),
    in_ontology(Ns,A,attribute(Human,show_as,shown(Thing,Purpose,Name))).
show_as(Thing, Purpose, Name) :-
    term_variables([Thing,Purpose,Name],[]), Thing = entity_ref(TNs,TA,Entity),
    personal_agent_owner(agent_instance_ref(Ns,A,Human)),
    (Name == default -> true; in_ontology(TNs,TA,entity_eidolons(Entity,Purpose,Name,[_|_]))),
    transaction(in_ontology(Ns,A,
        ((retract(attribute(Human,show_as,shown(Thing,Purpose,_))) -> true; true),
         (Name == default -> true; assertz(attribute(Human,show_as,shown(Thing,Purpose,Name))))))).

class_eidolon(human_user,operation(instance),controller_settings,recipe(Ns,A,controller_settings)) :-
    current_ontology_identity(Ns,A).
eidolon(controller_settings,subject(ontology_ref(Ns,A),instance(Human)),
        operation(Form)) :-
    HumanRef = entity_ref(Ns,A,Human),
    controller_preferences_current(HumanRef,Revision,Settings),
    controller_preferences_basis(Settings,Digest,State),
    (State = valid(_) -> Form = controller_settings(HumanRef,Revision,Digest)
    ; Form = controller_reset_settings(HumanRef,Revision,Digest)).

instance_of(quod:gui:form,controller_settings(H,_,_)) :- H = entity_ref(Ns,A,Id), in_ontology(Ns,A,instance_of(quod:user:human_user,Id)).
instance_of(quod:gui:form,controller_reset_settings(H,_,_)) :- H = entity_ref(Ns,A,Id), in_ontology(Ns,A,instance_of(quod:user:human_user,Id)).
instance_of(quod:gui:status,controller_invalid_settings).
instance_of(quod:gui:button,controller_restore).
instance_of(quod:gui:selection,controller_hand(R)) :- member(R,[navigation,menu]).
instance_of(quod:gui:selection,controller_role(Id)) :- controller_setting_id(Id).
instance_of(quod:gui:selection,controller_component(Id)) :- controller_setting_id(Id).
instance_of(quod:gui:selection,controller_modifier(Id)) :- member(Id,[drive,snap,teleport]).
instance_of(quod:gui:toggle,controller_enabled(Id)) :- controller_setting_id(Id).
instance_of(quod:gui:toggle,controller_reset).
instance_of(quod:gui:slider,controller_threshold(Id)) :- member(Id,[menu,snap,teleport]).
instance_of(quod:gui:slider,controller_teleport_fraction).
instance_of(quod:gui:button,controller_save).
controller_setting_id(Id) :- member(Id,[select,menu,drive,snap,teleport]).
attribute(controller_settings(_,_,_),label,<<"VR controller settings">>).
attribute(controller_settings(_,_,_),image,Icon) :- menu_icon(controllers,Icon).
attribute(controller_reset_settings(_,_,_),label,<<"Repair VR controller settings">>).
attribute(controller_reset_settings(_,_,_),image,Icon) :- menu_icon(controllers,Icon).
attribute(controller_invalid_settings,label,<<"Saved bindings are no longer valid. Controller input is disabled. Reset explicitly to the current shared defaults.">>).
attribute(controller_restore,label,<<"Reset to shared defaults">>).
attribute(controller_hand(R),label,Label) :-
    member(R-Label,[navigation - <<"Movement hand">>,menu - <<"Menu hand">>]).
attribute(controller_hand(_),options,[option(left,<<"Left">>),option(right,<<"Right">>),option(none,<<"Unspecified hand">>)]).
attribute(controller_role(Id),label,Label) :- controller_label(Id,<<" role">>,Label).
attribute(controller_role(drive),options,[option(navigation,<<"Movement controller">>),option(menu,<<"Menu controller">>)]).
attribute(controller_role(Id),options,[option(any,<<"Either controller">>),option(navigation,<<"Movement controller">>),option(menu,<<"Menu controller">>)]) :- Id \== drive.
attribute(controller_component(Id),label,Label) :- controller_label(Id,<<" input">>,Label).
attribute(controller_component(select),options,[option(trigger,<<"Trigger">>),option(grip,<<"Grip">>),option(pad,<<"Pad click">>)]).
attribute(controller_component(Id),options,[option(pad,<<"Touchpad">>)]) :- member(Id,[menu,drive,snap,teleport]).
attribute(controller_modifier(Id),label,Label) :- controller_label(Id,<<" grip modifier">>,Label).
attribute(controller_modifier(_),options,[option(grip,<<"Grip">>),option(trigger,<<"Trigger">>)]).
attribute(controller_enabled(Id),label,Label) :- controller_label(Id,<<" enabled">>,Label).
attribute(controller_threshold(Id),label,Label) :- controller_label(Id,<<" threshold">>,Label).
attribute(controller_threshold(_),range,range(1,999,1)).
attribute(controller_threshold(_),unit,permille).
attribute(controller_teleport_fraction,label,<<"Fraction of permitted teleport reach">>).
attribute(controller_teleport_fraction,range,range(1,999,1)).
attribute(controller_teleport_fraction,unit,permille).
attribute(controller_reset,label,<<"Reset all saved bindings to shared defaults">>).
attribute(controller_save,label,<<"Save controller settings">>).
controller_label(Id,Suffix,Label) :-
    member(Id-Name,[select - <<"Select">>,menu - <<"Menu">>,drive - <<"Travel">>,snap - <<"Turn">>,teleport - <<"Teleport">>]),
    binary_codes(Name,N),binary_codes(Suffix,S),append(N,S,C),binary_codes(Label,C).
gui_children(controller_settings(_,_,_),Children) :-
    findall(C,(controller_setting_id(Id),member(C,[controller_enabled(Id),controller_role(Id),controller_component(Id)])),Basic),
    append([controller_hand(navigation),controller_hand(menu)|Basic],
      [controller_modifier(drive),controller_modifier(snap),controller_modifier(teleport),
       controller_threshold(menu),controller_threshold(snap),controller_threshold(teleport),
       controller_teleport_fraction,controller_reset,controller_save],Children).
gui_children(controller_reset_settings(_,_,_),[controller_invalid_settings,controller_restore]).

gui_form(controller_reset_settings(H,R,D),[],
    submit(controller_restore,quod:user::controller_settings_save(H,R,D,true,[],[],Next),
      operation(configure_controller(R,D,reset),[result(revision,Next)]))).

gui_form(controller_settings(H,R,D),Fields,
    submit(controller_save,quod:user::controller_settings_save(H,R,D,Reset,Roles,Bindings,Next),
      operation(configure_controller(R,D,form(Roles,Bindings,Reset)),[result(revision,Next)]))) :-
    Roles = [role(navigation,hand(N)),role(menu,hand(M))],
    Bindings = [chosen(SE,bind(select,SR,SC,press_release,local(select))),
      chosen(ME,bind(menu,MR,MC,radial(MT),local(menu))),
      chosen(DE,bind(drive,DR,DC,axes_while(DG),control(drive))),
      chosen(TE,bind(snap,TR,TC,sector(horizontal,TT,TG),control(snap))),
      chosen(PE,bind(teleport,PR,PC,sector(forward,PT,PG),control(teleport(PF))))],
    Fields = [field(controller_hand(navigation),N),field(controller_hand(menu),M),
      field(controller_enabled(select),SE),field(controller_role(select),SR),field(controller_component(select),SC),
      field(controller_enabled(menu),ME),field(controller_role(menu),MR),field(controller_component(menu),MC),
      field(controller_enabled(drive),DE),field(controller_role(drive),DR),field(controller_component(drive),DC),
      field(controller_enabled(snap),TE),field(controller_role(snap),TR),field(controller_component(snap),TC),
      field(controller_enabled(teleport),PE),field(controller_role(teleport),PR),field(controller_component(teleport),PC),
      field(controller_modifier(drive),DG),field(controller_modifier(snap),TG),field(controller_modifier(teleport),PG),
      field(controller_threshold(menu),MT),field(controller_threshold(snap),TT),field(controller_threshold(teleport),PT),
      field(controller_teleport_fraction,PF),field(controller_reset,Reset)].

gui_initial(controller_settings(H,_,_),Field,Value) :-
    controller_preferences_current(H,_,settings(Roles,Set,Overrides)),
    controller_vocabulary(controller_configuration(settings(Roles,Set,Overrides),mapping(_,_,Effective,_))),
    controller_vocabulary(controller_default(Default)),
    controller_vocabulary(controller_configuration(Default,mapping(_,_,Defaults,_))),
    (Field = controller_hand(Role),member(role(Role,hand(Value)),Roles)
    ; Field = controller_reset,Value = false
    ; controller_setting_id(Id),
      (member(B,Effective),B = bind(Id,_,_,_,_) -> Enabled = true
      ; member(B,Defaults),B = bind(Id,_,_,_,_),Enabled = false),
      B = bind(Id,R,C,G,O),
      (Field = controller_enabled(Id),Value = Enabled
      ; Field = controller_role(Id),Value = R
      ; Field = controller_component(Id),Value = C
      ; Field = controller_modifier(Id),(G = axes_while(Value);G = sector(_,_,Value))
      ; Field = controller_threshold(Id),(G = radial(Value);G = sector(_,Value,_))
      ; Field = controller_teleport_fraction,O = control(teleport(Value)))).
controller_settings_save(H,R,D,Reset,Roles,Bindings,Next) :-
    (Reset = true -> controller_vocabulary(controller_default(Settings))
    ; Reset = false,controller_chosen(Bindings,Overrides),Settings = settings(Roles,vive_default,Overrides)),
    controller_preferences_set(H,R,D,Settings,Next).
controller_chosen([],[]).
controller_chosen([chosen(Enabled,B)|Rest],[Override|Tail]) :-
    B = bind(Id,_,_,_,_),
    (Enabled = true -> Override = replace(B);Enabled = false,Override = disable(Id)),
    controller_chosen(Rest,Tail).

can_request_agent_signature(Node, personal, Typed) :-
    Typed = agent_goal_v1(_, Responsible, _, _, _, _, _, _, _),
    <<"quod:gui">>::gui_completion_signing(Node, Responsible, Typed).

class_permission(human_user, answer_hud_offer, allow).
class_eidolon(human_user, attention, questions, recipe(Gui, A, attention)) :- gui_vocabulary(Gui, A).
class_eidolon(human_user, operation(instance), answer_hud_offer, recipe(Gui, A, answer_hud_offer)) :-
    gui_vocabulary(Gui, A).
