%% Private account composition. U, personal A and S0 share storage, never keys
%% or identities. Genesis is inert; only an explicit authorized setup constructs.
can_invoke(_, agent_instance_ref(Namespace, _, Instance), _, Namespace) :-
    instance_of(human_user, Instance).

human_user_owner(agent_instance_ref(Ns, Anchor, Instance)) :-
    current_ontology_identity(Ns, Anchor), instance_of(human_user, Instance).
ontology_source_mode(editable) :- current_principal(Owner), human_user_owner(Owner).
gui_pending_allowance(Instance, 8) :- instance_of(human_user, Instance).

account_setup_state(State) :-
    current_principal(Owner), human_user_owner(Owner),
    current_ontology_identity(Ns, Anchor),
    (account_setup(me, pending(account)) -> State = pending(ontology_ref(Ns, Anchor))
    ; account_setup(me, complete(State))).

account_navigation(Space, [playing, edition]) :-
    account_navigation(navigation(_,placed(Space,_),[playing,edition])).

%% Current location is the existing exclusive assignment, including unplaced.
%% The original setup result remains immutable and supplies no navigation state.
account_navigation(navigation(Revision,Location,[playing,edition])) :-
    current_principal(Owner), human_user_owner(Owner),
    account_setup(me, complete(_)), space_assignment(personal,Revision,_),
    space_location(personal,Location).

account_source_pins(Pins) :-
    findall(pins(AClass, G, C, S, Digest),
        (agent_vocabulary(<<"quod:agent">>, AClass),
         gui_vocabulary(<<"quod:gui">>, G),
         controllers_vocabulary(<<"quod:controllers">>, C),
         space_vocabulary(<<"quod:space">>, S), space_source_digest(Digest)), [Pins]).

%% A source pin certifies the original composed implementation, not a class
%% alias. The selected storage owns its local class and every new instance.
account_space_recipe(Pins) :-
    account_source_pins(Pins), space_recipe.

account_setup_preparation(Preparation) :-
    current_principal(Owner), human_user_owner(Owner),
    (account_setup(me, complete(Result)) -> Preparation = complete(Result)
    ; account_setup(me, pending(account)), account_space_recipe(_),
      space_location(me, unplaced), space_location(personal, unplaced),
      hosting_node(Node), current_ontology_identity(Ns, Anchor),
      prepare_agent_key_custody(agent_instance_ref(Ns, Anchor, personal), none, 0, Node, Key, Receipt),
      Preparation = prepared(ontology_ref(Ns, Anchor), Node, prepared_key(Key, Receipt))).

setup_account(Storage, Node, Custody, Result) :-
    current_principal(Owner), human_user_owner(Owner),
    term_variables([Storage, Node, Custody], []), Custody = prepared_key(Key, Receipt),
    current_ontology_identity(Ns, Anchor), Storage = ontology_ref(Ns, Anchor),
    account_setup(me, pending(account)), account_space_recipe(Pins),
    space_location(me, unplaced), space_location(personal, unplaced),
    hosting_node(Node), agent_preparation_assignment(personal, none, 0), agent_identifier(Key),
    Agent = agent_instance_ref(Ns, Anchor, personal),
    prepared_agent_key_custody(Agent, none, 0, Node, Key, Receipt),
    Inputs = [attribute(owner, Owner),
        part(initial_occupants, [attribute(entities, [entity_ref(Ns, Anchor, personal)])])],
    transaction((
        goal(agent_hosted(personal, Node, 1, Key)),
        assertz(attribute(personal, transform, transform(0,0,0,0,0,0))),
        with_build_plan(Inputs, assert(instance_of(space, Space))),
        Result = account(Owner, Agent, entity_ref(Ns, Anchor, Space), Storage, Key, Pins),
        retract(account_setup(me, pending(account))),
        assertz(account_setup(me, complete(Result))),
        signup_origin(Signup, SignupAnchor, Token),
        Signup::(current_ontology_identity(Signup, SignupAnchor), acknowledge_signup(Token, Owner)),
        retract(signup_origin(Signup, SignupAnchor, Token)))).

%% These committed grants exist before construction. Staged memberships or
%% permissions cannot authorize creation, source entry or destination admission.
class_permission(space, create, check(account_space_create)).
class_permission(space, space_admit, check(account_space_admit)).
class_permission(space, space_enter, check(account_new_space_entry)).
class_permission(agent, space_enter, check(account_agent_entry)).
class_permission(agent, space_leave, check(account_agent_leave)).
class_permission(space, space_visit, check(account_space_visit)).
class_permission(space, space_represent, check(account_space_represent)).

account_space_create(Owner, class(space), create(Inputs)) :-
    account_setup(me, pending(account)),
    Owner = agent_instance_ref(Ns, Anchor, me),
    account_owner_policy(Owner),
    Inputs = [attribute(owner, Owner),
        part(initial_occupants, [attribute(entities, [entity_ref(Ns, Anchor, personal)])])].
account_space_create(Actor, class(space), create(Inputs)) :-
    account_personal_actor(Actor, Owner),
    (member(attribute(owner, Supplied), Inputs) -> Supplied = Owner; true),
    \+ member(part(initial_occupants, _), Inputs).

account_personal_actor(Actor, Owner) :-
    Actor = agent_instance_ref(Ns, Anchor, personal),
    personal_instruction(Owner, _, authority(UKey, Key, _), _, _, _, _),
    Owner = agent_instance_ref(Ns, Anchor, me), account_owner_policy(Owner),
    agent_key(me, UKey, active),
    can_instruct_personal_agent(Owner, agent_goal_v1(_, Actor, _, Key, _, _, execute, 3, _)).

%% Invocation already authenticates the exact history. A committed operation
%% callback uses its supplied references and local facts, never a native read.
account_owner_policy(agent_instance_ref(Ns, _, me)) :-
    user_namespace(Ns), instance_of(human_user, me).

account_initial_entry(Owner, instance(personal),
    space_enter(entity_ref(Ns, Anchor, personal), entity_ref(Ns, Anchor, _), placement)) :-
    account_setup(me, pending(account)), account_owner_policy(Owner),
    Owner = agent_instance_ref(Ns, Anchor, me).
account_agent_entry(Actor, Subject, Operation) :- account_initial_entry(Actor,Subject,Operation).
account_agent_entry(Actor, instance(personal),
    space_enter(entity_ref(Ns,Anchor,personal),_,placement)) :-
    account_setup(me,complete(_)), account_personal_actor(Actor,_),
    Actor = agent_instance_ref(Ns,Anchor,personal).
account_agent_leave(Actor, instance(personal),
    space_leave(entity_ref(Ns,Anchor,personal),_,placement)) :-
    account_setup(me,complete(_)), account_personal_actor(Actor,_),
    Actor = agent_instance_ref(Ns,Anchor,personal).
account_space_admit(Owner, construction(space, Space, Inputs),
    space_admit(entity_ref(Ns, Anchor, Space), entity_ref(Ns, Anchor, personal), placement)) :-
    account_space_create(Owner, class(space), create(Inputs)).

%% Later construction is distinct from onboarding's initial-occupant grant.
%% Only the active new-space constructor gets this source-entry grant. A's
%% later travel uses the distinct committed agent entry/leave policies above.
account_new_space_entry(Actor, construction(space, Space, Inputs),
    space_enter(entity_ref(_, _, Space), _, placement)) :-
    account_space_create(Actor, class(space), create(Inputs)).
account_space_admit(Actor, instance(Space),
    space_admit(entity_ref(Ns, Anchor, Space), Source, placement)) :-
    account_setup(me, complete(_)), account_personal_actor(Actor, Owner),
    Actor = agent_instance_ref(Ns, Anchor, personal),
    attribute(Space, owner, Owner), term_variables(Source,[]).

%% Reads and callbacks retain the original personal actor and exact history.
space_travel_agent(Actor) :-
    account_setup(me,complete(_)), current_principal(Principal),
    (human_user_owner(Principal) -> personal_agent(Actor,_)
    ; once(account_personal_actor(Principal,_)), Actor = Principal).
account_space_visit(Principal,instance(Space),space_visit(Actor,_)) :-
    account_setup(me,complete(_)),
    Actor = agent_instance_ref(Ns,Anchor,personal),
    attribute(Space,owner,Owner), Owner = agent_instance_ref(Ns,Anchor,me),
    (Principal = Owner, account_owner_policy(Owner)
    ; Principal = Actor, account_personal_actor(Actor,Owner)).
account_space_represent(Principal,instance(Space),space_represent(_,_,_,_,_,_)) :-
    account_setup(me,complete(_)), attribute(Space,owner,Owner),
    (Principal = Owner, account_owner_policy(Owner)
    ; account_personal_actor(Principal,Owner)).
can_invoke((current_ontology_identity(Ns,Anchor),space_travel(personal,_,_,_,_)),
           Actor,_,Ns) :-
    Actor = agent_instance_ref(Ns,Anchor,personal), account_personal_actor(Actor,_).
can_invoke((current_ontology_identity(Ns,Anchor),space_release_placement(Space,_,_,_)),
           Actor,_,Ns) :-
    Actor = agent_instance_ref(Ns,Anchor,personal), account_setup(me,complete(_)),
    attribute(Space,owner,agent_instance_ref(Ns,Anchor,me)).
can_invoke((current_ontology_identity(Ns,Anchor),space_representation_changed(Space,_)),
           Actor,_,Ns) :-
    Actor = agent_instance_ref(Ns,Anchor,personal), account_personal_actor(Actor,_),
    attribute(Space,owner,agent_instance_ref(Ns,Anchor,me)).

%% The exact anchored callback is entered by the existing atomic placement
%% owner. This grants neither arbitrary A invocation nor source-side consent.
can_invoke((current_ontology_identity(Ns, Anchor), space_accept_placement(Space, _, _)),
           Actor, _, Ns) :-
    Actor = agent_instance_ref(Ns, Anchor, personal),
    account_setup(me, complete(_)),
    attribute(Space, owner, agent_instance_ref(Ns, Anchor, me)).
can_invoke((current_ontology_identity(Ns, Anchor), space_assignment(_, _, _)),
           agent_instance_ref(Ns, Anchor, personal), _, Ns) :- account_setup(me, complete(_)).

%% Ordinary S0 has no visible body, floor, sky or simulation. A's source still
%% participates in the normal scene dependency and disclosure proof.
entity_scene(personal, Mode, hidden) :- member(Mode, [playing, edition]).

%% The human and personal actor share account storage, never identity or keys.
instance_of(agent, personal).

%% Pointing at nothing while unplaced targets the agent itself: its pie is
%% the ways in. Known spaces of this storage, creating one, and the human's
%% own choices; the same menu serves while placed.
class_eidolon(agent,menu,default,recipe(Ns,A,personal_menu)) :- current_ontology_identity(Ns,A).
eidolon(personal_menu,subject(ontology_ref(Ns,A),personal),menu(Tree)) :-
    current_ontology_identity(Ns,A),
    findall(Item,personal_menu_destination(Item),Known),
    gui_menu_source(space,menu_source(_,Create)),
    findall(Item,(instance_of(human_user,Human),gui_menu_source(Human,menu_source(_,Own)),member(Item,Own)),Account),
    (space_location(personal,unplaced) -> Title = <<"You are nowhere yet">>; Title = <<"You">>),
    menu_vocabulary(Gui,GuiAnchor),
    in_ontology(Gui,GuiAnchor,menu_tree(menu(Title,<<"">>,[],
        [group(<<"Enter a known space">>,[slot(1)],[operation(instance)],Known),
         group(<<"Create a space">>,[slot(3)],[operation(class)],Create),
         group(<<"Your account">>,[slot(5)],[operation(instance),playing,edition,prolog,inspection,workspace],Account)]),Tree)).
%% The human is an agent too and keeps the shared default pie.
eidolon(personal_menu,subject(Target,Entity),View) :-
    Entity \== personal, menu_vocabulary(Gui,GuiAnchor),
    in_ontology(Gui,GuiAnchor,eidolon(default_menu,subject(Target,Entity),View)).
personal_menu_destination(item(T,Label,H,Av,[])) :-
    space_instance(Space,space), Space \= ontology_ref(_,_),
    gui_menu_source(Space,menu_source(Name,Items)),
    member(item(T,Offered,H,Av,_),Items), T = choice(_,eidolon(operation(instance),enter,_)),
    (binary(Name), Name \== <<"">> -> Label = Name; Label = Offered).

%% A's constructor queries its existing account relationship and location;
%% neither a target's proposed owner nor a failed lookup supplies this evidence.
personal_agent_owner(Owner) :-
    current_principal(agent_instance_ref(Ns, Anchor, personal)),
    current_ontology_identity(Ns, Anchor),
    findall(Human, human_user_owner(Human), [Owner]).
personal_agent_query(personal_agent_owner(_)).
personal_agent_query(space_location(personal, _)).
personal_agent_query(space_travel_agent(_)).
can_invoke((current_ontology_identity(Ns, Anchor), Query),
           agent_instance_ref(Ns, Anchor, personal), _, Ns) :-
    personal_agent_query(Query).

personal_agent(Agent, Key) :-
    current_principal(Owner), human_user_owner(Owner),
    current_ontology_identity(Ns, Anchor),
    Agent = agent_instance_ref(Ns, Anchor, personal),
    hosting_node(Node), agent_hosted(personal, Node, _, Key).

personal_agent_preparation(Preparation) :-
    current_principal(Owner), human_user_owner(Owner),
    hosting_node(Node),
    (agent_hosted(personal, Node, _, _) -> Preparation = ready
    ; current_ontology_identity(Ns, Anchor),
      prepare_agent_key_custody(agent_instance_ref(Ns, Anchor, personal), none, 0, Node, Key),
      Preparation = prepared(Node, Key)).


can_prepare_agent_key(Owner, personal, none, 0, Node) :-
    Owner = agent_instance_ref(_, _, Human), instance_of(human_user, Human), hosting_node(Node).
can_assign_agent_host(Owner, personal, none, 0, Node, _) :-
    Owner = agent_instance_ref(_, _, Human), instance_of(human_user, Human), hosting_node(Node).

%% Admission is a committed read, not a stored task. The instruction endpoint
%% attempts it only in an already installed, idle hosted incarnation.
personal_instruction_accept(Bytes, Signature) :-
    current_principal(Owner),
    agent_request_bytes(Typed, Bytes),
    can_instruct_personal_agent(Owner, Typed),
    Typed = agent_goal_v1(_, _, _, _, _, Expiry, _, _, _),
    current_request_expiry(Deadline), Expiry =< Deadline,
    sign_agent_request(Typed, Signature).

can_instruct_personal_agent(Owner,
    agent_goal_v1(_, agent_instance_ref(Ns, Anchor, personal), _, Key, _, _, execute, 3, _)) :-
    Owner = agent_instance_ref(Ns, Anchor, Human), instance_of(human_user, Human),
    hosting_node(Node), agent_hosted(personal, Node, _, Key),
    \+ agent_hosting_suspended(personal).

%% Signature verification supplies data only. The committed human key and
%% current hosting/signing policy provide authority, including revocation.
personal_instruction_authorized(UBytes, USignature, Typed, Owner, UKey) :-
    signed_agent_request(UBytes, USignature,
        agent_goal_v1(Network, Owner, _, UKey, _, Expiry, read, 3, Text)),
    Owner = agent_instance_ref(_, _, Human), instance_of(human_user, Human),
    agent_key(Human, UKey, active),
    '$quod_program_source'([personal_instruction_accept(Bytes, _)], Text),
    agent_request_bytes(Typed, Bytes),
    Typed = agent_goal_v1(Network, _, _, _, _, TargetExpiry, execute, 3, _),
    TargetExpiry =< Expiry,
    can_instruct_personal_agent(Owner, Typed).

can_invoke((agent_hosted(personal, Node, Epoch, Key), sign_agent_request(_, _)), Node, _, _) :-
    hosting_node(Node), agent_hosted(personal, Node, Epoch, Key).

can_sign_agent_request(Owner, Node, Typed) :-
    hosting_node(Node), can_instruct_personal_agent(Owner, Typed).

can_request_agent_signature(Node, personal,
    agent_goal_v1(Network, Actor, _, Key, _, Expiry, execute, 3, Text)) :-
    hosting_node(Node),
    '$quod_program_source'([retain_personal_instruction(UBytes, USignature, Signature)], Text),
    personal_instruction_authorized(UBytes, USignature, Requested, _, _),
    Requested = agent_goal_v1(Network, Actor, _, Key, _, Expiry, execute, 3, _),
    agent_request_bytes(Requested, Bytes),
    signed_agent_request(Bytes, Signature, Requested).

can_invoke(retain_personal_instruction(_, _, _), Actor, _, Ns) :-
    Actor = agent_instance_ref(Ns, _, personal).
can_invoke(personal_instruction_retained(_, _), Node, _, _) :- hosting_node(Node).
%% Custody verified these fields once. Match the goal before consulting current
%% authority; authorization never reparses or reverifies historical signatures.
can_invoke(Goal, Actor, _, Ns) :-
    Actor = agent_instance_ref(Ns, _, personal),
    variant_digest(Goal, Digest),
    personal_instruction(Owner, _, authority(UKey, Key, Digest), _, _, _, _),
    Owner = agent_instance_ref(_, _, Human), agent_key(Human, UKey, active),
    can_instruct_personal_agent(Owner,
        agent_goal_v1(_, Actor, _, Key, _, _, execute, 3, _)).

%% Only the authenticated association is stored here. Outcomes and returned
%% bindings remain in the original transaction/outcome owners. No reaction or
%% recovery selector dispatches these records.
retain_personal_instruction(UBytes, USignature, Signature) :-
    personal_instruction_authorized(UBytes, USignature, Typed, Owner, UKey),
    agent_request_bytes(Typed, Bytes),
    signed_agent_request(Bytes, Signature, Typed),
    Typed = agent_goal_v1(_, Actor, _, Key, Id, _, execute, 3, Text),
    '$quod_program_source'([Requested], Text), variant_digest(Requested, Digest),
    current_principal(Actor),
    transaction((\+ personal_instruction(_, Id, _, _, _, _, _),
                 assertz(personal_instruction(Owner, Id, authority(UKey, Key, Digest),
                                              UBytes, USignature, Bytes, Signature)))).

%% The hosted worker asks only after a definite refusal, while it still owns
%% the actor slot. An older association keeps the original operation uncertain.
personal_instruction_retained(Bytes, Retained) :-
    agent_request_bytes(agent_goal_v1(_, _, _, _, Id, _, execute, 3, _), Bytes),
    (personal_instruction(_, Id, _, _, _, _, _) -> Retained = true; Retained = false).

personal_instruction_lookup(Id, Bytes, Signature) :-
    current_principal(Owner), human_user_owner(Owner),
    (personal_instruction(Owner, Id, _, _, _, Bytes, Signature) -> true
    ; Bytes = none, Signature = none).

personal_instructions(Instructions) :-
    current_principal(Owner), human_user_owner(Owner),
    findall(instruction(Id, Bytes, Signature),
            personal_instruction(Owner, Id, _, _, _, Bytes, Signature), Instructions).

%% A human's HUD stores references only. Status and accepted fields stay in
%% the responsible ontology. Compose with the human's ordinary identity rules.
no_follow(gui_unlink/2).
no_follow(gui_hud_entry/4).
no_follow(gui_pending/2).
no_follow(gui_pending_questions/1).
no_follow(gui_select_receiver/3).
no_follow(gui_selected_receiver/3).
no_follow(gui_receiver_for/2).
no_follow(gui_forget_receivers/1).

can_invoke(Goal, Principal, Chain, Ns) :- gui_hud_entry(Goal, Principal, Chain, Ns).
gui_hud_entry((current_ontology_identity(_, _), Goal), Principal, Chain, Ns) :-
    gui_hud_entry(Goal, Principal, Chain, Ns).
gui_hud_entry(gui_pending_questions(_), agent_instance_ref(Ns, _, Instance), _, Ns) :-
    instance_of(human_user, Instance).
gui_hud_entry(gui_select_receiver(Instance, _, _), agent_instance_ref(Ns, _, Instance), _, Ns) :-
    instance_of(human_user, Instance).
gui_hud_entry(gui_receiver_for(Instance, _), Principal, _, Ns) :-
    instance_of(human_user, Instance),
    (Principal = agent_instance_ref(Ns, _, Instance); gui_receiver_policy(Instance, Principal)).
gui_hud_entry(gui_unlink(Instance, question_ref(Ns, Anchor, Q)), _, [Ns|_], _) :-
    instance_of(human_user, Instance),
    gui_pending(Instance, question_ref(Ns, Anchor, Q)).

%% Discovery returns references from the authenticated human's own ontology.
%% It neither scans applications nor copies their status or accepted answers.
gui_pending_questions(References) :-
    current_ontology_identity(Ns, Anchor),
    current_principal(agent_instance_ref(Ns, Anchor, Instance)),
    instance_of(human_user, Instance),
    findall(Reference, gui_pending(Instance, Reference), Pending),
    sort(Pending, References).

%% The human chooses one receiving scope, including when several tabs exist.
%% This durable route is never treated as evidence that a client is still live.
gui_select_receiver(Instance, Node, Token) :-
    term_variables([Instance, Node, Token], []),
    current_ontology_identity(Ns, Anchor),
    current_principal(agent_instance_ref(Ns, Anchor, Instance)),
    instance_of(human_user, Instance),
    binary_codes(Node, NodeBytes), length(NodeBytes, 32),
    binary_codes(Token, TokenBytes), length(TokenBytes, 32),
    transaction((
        findall(gui_selected_receiver(Instance, N, T), gui_selected_receiver(Instance, N, T), Previous),
        (Previous = [gui_selected_receiver(Instance, Node, Token)] -> true
        ; gui_forget_receivers(Previous), assertz(gui_selected_receiver(Instance, Node, Token))))).

gui_forget_receivers([]).
gui_forget_receivers([Row|Rows]) :- retract(Row), gui_forget_receivers(Rows).

gui_receiver_for(Instance, receiver(Node, Token)) :-
    term_variables(Instance, []), instance_of(human_user, Instance),
    current_ontology_identity(Ns, Anchor), current_principal(Principal),
    (Principal = agent_instance_ref(Ns, Anchor, Instance); gui_receiver_policy(Instance, Principal)),
    findall(receiver(N, T), gui_selected_receiver(Instance, N, T), [receiver(Node, Token)]).

%% The exact responder must authorize retirement from its still-current row.
%% Call-chain admission restricts this mutation to the responder's shared
%% completion/cancellation transition, whose outer transaction owns rollback.
gui_unlink(Instance, Reference) :-
    term_variables([Instance, Reference], []),
    instance_of(human_user, Instance),
    current_ontology_identity(HumanNs, HumanAnchor),
    Human = agent_instance_ref(HumanNs, HumanAnchor, Instance),
    Reference = question_ref(Ns, Anchor, Q),
    Ns::(current_ontology_identity(Ns, Anchor), gui_retirement(Q, Human)),
    retract(gui_pending(Instance, Reference)).

%% Authored human capacity is shared by committed opening and native admission.
%% A live connection never substitutes for this ordinary ontology policy.
no_follow(gui_receiver_accept/3).
gui_hud_entry(gui_receiver_accept(Instance, _, _), Principal, Chain, Ns) :-
    gui_hud_entry(gui_receiver_for(Instance, _), Principal, Chain, Ns).
gui_receiver_accept(Instance, Receiver, Capacity) :-
    gui_receiver_for(Instance, Receiver),
    findall(Limit, gui_pending_allowance(Instance, Limit), [Capacity]),
    integer(Capacity), Capacity > 0,
    findall(Q, gui_pending(Instance, Q), Pending), length(Pending, Count),
    Count < Capacity.

no_follow(gui_link_question/1).
gui_hud_entry(gui_link_question(Opening), Principal, [ActorNs|_], Ns) :-
    Opening = gui_opening(_, _, _, agent_instance_ref(Ns, _, Instance),
        agent_instance_ref(ActorNs, _, _), _, _, _, _),
    gui_hud_entry(gui_receiver_for(Instance, _), Principal, [], Ns).
gui_link_question(Opening) :-
    term_variables(Opening, []),
    Opening = gui_opening(_, Reference, _, agent_instance_ref(Ns, Anchor, Instance),
        agent_instance_ref(ActorNs, ActorAnchor, _), _, Receiver, _, Capacity),
    current_ontology_identity(Ns, Anchor),
    gui_receiver_accept(Instance, Receiver, Capacity),
    ActorNs::(current_ontology_identity(ActorNs, ActorAnchor), gui_accepting(Opening)),
    \+ gui_pending(Instance, Reference), assertz(gui_pending(Instance, Reference)).

%% The human's HUD. Commands are references, as gui_pending/2 stores question
%% references: standing ones, those offered by the space the agent is placed
%% in, then accepted contributions in acceptance order. The client's own
%% "This device" command is the only one not authored here (decision 3).
instance_of(quod:gui:hud, my_hud).
%% Authored allowance before "More" (decision 5), beside gui_pending_allowance/2.
hud_allowance(my_hud, 12).
no_follow(hud_commands/1).
no_follow(hud_command/1).
no_follow(hud_direct_contributor/1).
no_follow(hud_contribute/2).
no_follow(hud_withdraw/2).
hud_commands(hud(Tree)) :-
    current_principal(Owner), human_user_owner(Owner),
    findall(Item, hud_command(Item), Items),
    findall(N, hud_allowance(my_hud, N), [Allowance]),
    menu_vocabulary(Gui, GuiAnchor),
    in_ontology(Gui, GuiAnchor, menu_tree(menu(<<"Commands">>, <<"">>, [wedges(Allowance)], Items), Tree)).

hud_command(item(choice(Me, Choice), <<"Your attention">>, <<"Questions waiting for you">>, available, [image(Icon)])) :-
    current_ontology_identity(Ns, A), Me = entity_ref(Ns, A, me),
    entity_eidolons(me, attention, _, [Choice]), gui_icon(attention, Icon).
hud_command(item(choice(Me, Choice), <<"Me">>, <<"Your settings, keys and account">>, available, [image(Icon)])) :-
    current_ontology_identity(Ns, A), Me = entity_ref(Ns, A, me),
    entity_eidolons(me, menu, _, [Choice]), gui_icon(me, Icon).
%% The vocabulary's icon catalogue, by name.
gui_icon(Name, Icon) :- menu_vocabulary(Gui, GuiAnchor), in_ontology(Gui, GuiAnchor, gui_icon(Name, Icon)).
hud_command(Item) :-
    space_location(personal, placed(entity_ref(Ns, A, Space), _)),
    in_ontology(Ns, A, (entity_eidolons(Space, hud, _, Choices), member(Choice, Choices),
                        client_eidolon(Space, Choice, hud(Items)))),
    member(Item, Items).
%% A human placed the contribution; an unreadable source stays, dimmed.
hud_command(Item) :-
    hud_contribution(my_hud, Subject, Choice, _),
    Subject = entity_ref(Ns, A, Entity),
    (in_ontology(Ns, A, gui_menu_source(Entity, menu_source(_, Items))),
     member(Offered, Items), Offered = item(choice(Subject, Choice), _, _, _, _) -> Item = Offered
    ; Item = item(choice(Subject, Choice), <<"Unavailable">>, <<"">>, unreachable, [])).

%% The question count is the existing pending-question view, as a choice.
class_eidolon(human_user, attention, questions, recipe(Ns, A, attention)) :- current_ontology_identity(Ns, A).
eidolon(attention, subject(_, Human), attention(References)) :-
    instance_of(human_user, Human), gui_pending_questions(References).

%% The human, the personal agent and the owner of the space the agent is
%% placed in add commands directly; the human removes any, a contributor its
%% own. Admission names exactly those principals: nobody else reaches these.
can_invoke(Goal, Principal, _, _) :- hud_entry(Goal, Principal).
can_invoke((current_ontology_identity(_, _), Goal), Principal, _, _) :- hud_entry(Goal, Principal).
hud_entry(hud_contribute(_, _), Principal) :- hud_direct_contributor(Principal).
hud_entry(hud_withdraw(Subject, Choice), Principal) :-
    (human_user_owner(Principal) ; hud_contribution(my_hud, Subject, Choice, Principal)).
hud_direct_contributor(Principal) :- human_user_owner(Principal).
hud_direct_contributor(agent_instance_ref(Ns, A, personal)) :- current_ontology_identity(Ns, A).
hud_direct_contributor(Principal) :-
    space_location(personal, placed(entity_ref(Ns, A, Space), _)),
    in_ontology(Ns, A, attribute(Space, owner, Principal)).
hud_contribute(Subject, Choice) :-
    term_variables([Subject, Choice], []),
    Subject = entity_ref(_, _, _), Choice = eidolon(_, Style, recipe(_, _, _)), atom(Style),
    current_principal(Principal), hud_direct_contributor(Principal),
    transaction((\+ hud_contribution(my_hud, Subject, Choice, _),
                 assertz(hud_contribution(my_hud, Subject, Choice, Principal)))).
%% An agent the human already lets put questions before them (their authored
%% gui_receiver_policy/2) may leave an offer instead. It waits here, unplaced,
%% until the human's own signed answer places or drops it; no foreign answer is
%% trusted. A contributor may withdraw its own waiting offer. Nobody else writes.
can_invoke(Goal, Principal, _, _) :- hud_offer_entry(Goal, Principal).
can_invoke((current_ontology_identity(_, _), Goal), Principal, _, _) :- hud_offer_entry(Goal, Principal).
hud_offer_entry(hud_offer(_, _), Principal) :-
    instance_of(human_user, Instance), gui_receiver_policy(Instance, Principal).
hud_offer_entry(hud_withdraw_offer(Subject, Choice), Principal) :- hud_offered(my_hud, Principal, Subject, Choice).
no_follow(hud_offer/2).
no_follow(hud_withdraw_offer/2).
no_follow(hud_answer_offer/3).
hud_offer(Subject, Choice) :-
    term_variables([Subject, Choice], []),
    Subject = entity_ref(_, _, _), Choice = eidolon(_, Style, recipe(_, _, _)), atom(Style),
    current_principal(Principal),
    (hud_direct_contributor(Principal) -> fail_with_reason(hud_contribute_directly); true),
    transaction((\+ hud_offered(my_hud, _, Subject, Choice), \+ hud_contribution(my_hud, Subject, Choice, _),
                 assertz(hud_offered(my_hud, Principal, Subject, Choice)))).
hud_withdraw_offer(Subject, Choice) :-
    term_variables([Subject, Choice], []), current_principal(Principal),
    transaction(retract(hud_offered(my_hud, Principal, Subject, Choice))).
%% The human's answer is an ordinary offered operation of their own instance.
class_permission(human_user, answer_hud_offer, check(hud_answer_actor)).
hud_answer_actor(Actor, instance(Human), answer_hud_offer(_, _)) :-
    Owner = agent_instance_ref(_, _, Human),
    (Actor = Owner, account_owner_policy(Owner) ; account_personal_actor(Actor, Owner)).
hud_answer_offer(Human, Offer, Answer) :-
    term_variables([Human, Offer, Answer], []),
    Offer = offer(Contributor, Subject, Choice),
    operation_authorized(instance(Human), answer_hud_offer(Offer, Answer)),
    transaction((retract(hud_offered(my_hud, Contributor, Subject, Choice)),
                 (Answer == accept -> assertz(hud_contribution(my_hud, Subject, Choice, Contributor)); true))).
%% Offered only while something waits: an advertised choice always opens.
class_eidolon(human_user, operation(instance), answer_hud_offer, recipe(Ns, A, answer_hud_offer)) :-
    current_ontology_identity(Ns, A), once(hud_offered(my_hud, _, _, _)).
eidolon(answer_hud_offer, subject(ontology_ref(Ns, A), instance(Human)), operation(hud_offers(Human))) :-
    current_ontology_identity(Ns, A), instance_of(human_user, Human), once(hud_offered(my_hud, _, _, _)).
instance_of(quod:gui:form, hud_offers(H)) :- instance_of(human_user, H).
instance_of(quod:gui:selection, hud_offer_choice).
instance_of(quod:gui:selection, hud_offer_answer).
instance_of(quod:gui:button, hud_offer_submit).
attribute(hud_offers(_), label, <<"Offered commands">>).
attribute(hud_offers(_), image, Icon) :- gui_icon(question, Icon).
attribute(hud_offers(_), help, <<"Other agents asked to add these commands to your HUD. Nothing is added unless you accept.">>).
attribute(hud_offer_choice, label, <<"Offer">>).
attribute(hud_offer_choice, options, Options) :-
    findall(option(offer(P, S, C), Label), (hud_offered(my_hud, P, S, C), hud_offer_label(S, C, Label)), Options).
attribute(hud_offer_answer, label, <<"Answer">>).
attribute(hud_offer_answer, options, [option(accept, <<"Add it to my HUD">>), option(decline, <<"Decline">>)]).
attribute(hud_offer_submit, label, <<"Answer">>).
gui_children(hud_offers(_), [hud_offer_choice, hud_offer_answer, hud_offer_submit]).
gui_initial(hud_offers(_), hud_offer_answer, decline).
gui_form(hud_offers(Human), [field(hud_offer_choice, Offer), field(hud_offer_answer, Answer)],
    submit(hud_offer_submit, hud_answer_offer(Human, Offer, Answer), operation(answer_hud_offer(Offer, Answer), []))).
%% The command's own label from its source, or a plain placeholder.
hud_offer_label(entity_ref(Ns, A, Entity), Choice, Label) :-
    (in_ontology(Ns, A, gui_menu_source(Entity, menu_source(_, Items))),
     member(item(choice(_, Choice), Offered, _, _, _), Items), binary(Offered) -> Label = Offered
    ; Label = <<"A command whose source can't be reached">>).

%% The human removes any contribution; a contributor withdraws its own.
hud_withdraw(Subject, Choice) :-
    term_variables([Subject, Choice], []), current_principal(Principal),
    transaction((hud_contribution(my_hud, Subject, Choice, Contributor),
                 (human_user_owner(Principal) -> true; Principal = Contributor),
                 retract(hud_contribution(my_hud, Subject, Choice, Contributor)))).

%% Private human preferences. Connection, pose and button observations never
%% enter this source. Compose the existing GUI form and operation owners.
have_attribute(human_user,controller_preferences,controller_preferences).
class_permission(human_user,configure_controller,allow).
class_requirement(human_user,configure_controller,controller_actor).
controller_actor(Actor,instance(Human),configure_controller(_,_,_)) :-
    personal_instruction(Owner,_,authority(UKey,Key,_),_,_,_,_),
    Owner = agent_instance_ref(Ns,A,Human), Actor = agent_instance_ref(Ns,A,personal),
    agent_key(Human,UKey,active),
    can_instruct_personal_agent(Owner,agent_goal_v1(_,Actor,_,Key,_,_,execute,3,_)).

controller_read(Human) :-
    current_principal(Owner),human_user_owner(Owner),Owner = agent_instance_ref(_,_,Human).
controller_preferences_current(Human,Revision,Settings) :-
    instance_of(human_user,Human),
    findall(P,attribute(Human,controller_preferences,P),Rows),
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
    operation_authorized(instance(Human),configure_controller(Expected,ExpectedDigest,Settings)),
    transaction((controller_preferences_current(Human,Expected,Previous),
      controller_preferences_basis(Previous,ExpectedDigest,_),
      controller_vocabulary(controller_configuration(Settings,_)),
      (Expected = 0 -> true; retract(attribute(Human,controller_preferences,preferences(Expected,Previous)))),
      Next is Expected + 1,
      assertz(attribute(Human,controller_preferences,preferences(Next,Settings))))).

class_eidolon(human_user,operation(instance),controller_settings,recipe(Ns,A,controller_settings)) :-
    current_ontology_identity(Ns,A).
eidolon(controller_settings,subject(ontology_ref(Ns,A),instance(Human)),
        operation(Form)) :-
    current_ontology_identity(Ns,A),
    controller_preferences_current(Human,Revision,Settings),
    controller_preferences_basis(Settings,Digest,State),
    (State = valid(_) -> Form = controller_settings(Human,Revision,Digest)
    ; Form = controller_reset_settings(Human,Revision,Digest)).

instance_of(quod:gui:form,controller_settings(H,_,_)) :- instance_of(human_user,H).
instance_of(quod:gui:form,controller_reset_settings(H,_,_)) :- instance_of(human_user,H).
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
attribute(controller_settings(_,_,_),image,Icon) :- gui_icon(controllers,Icon).
attribute(controller_reset_settings(_,_,_),label,<<"Repair VR controller settings">>).
attribute(controller_reset_settings(_,_,_),image,Icon) :- gui_icon(controllers,Icon).
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
    submit(controller_restore,controller_settings_save(H,R,D,true,[],[],Next),
      operation(configure_controller(R,D,reset),[result(revision,Next)]))).

gui_form(controller_settings(H,R,D),Fields,
    submit(controller_save,controller_settings_save(H,R,D,Reset,Roles,Bindings,Next),
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
