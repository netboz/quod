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
    current_principal(Owner), human_user_owner(Owner),
    account_setup(me, complete(_)), space_location(personal, placed(Space, _)).

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
class_permission(agent, space_enter, check(account_initial_entry)).

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
account_space_admit(Owner, construction(space, Space, Inputs),
    space_admit(entity_ref(Ns, Anchor, Space), entity_ref(Ns, Anchor, personal), placement)) :-
    account_space_create(Owner, class(space), create(Inputs)).

%% Later construction is distinct from onboarding's initial-occupant grant.
%% Only the active new-space constructor gets source entry; A's own travel
%% remains separately denied until its entry/leave policy is authored.
account_new_space_entry(Actor, construction(space, Space, Inputs),
    space_enter(entity_ref(_, _, Space), _, placement)) :-
    account_space_create(Actor, class(space), create(Inputs)).
account_space_admit(Actor, instance(Space),
    space_admit(entity_ref(Ns, Anchor, Space), Source, placement)) :-
    account_setup(me, complete(_)), account_personal_actor(Actor, Owner),
    Actor = agent_instance_ref(Ns, Anchor, personal),
    attribute(Space, owner, Owner),
    Source \== entity_ref(Ns, Anchor, personal).

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

%% A's constructor queries its existing account relationship and location;
%% neither a target's proposed owner nor a failed lookup supplies this evidence.
personal_agent_owner(Owner) :-
    current_principal(agent_instance_ref(Ns, Anchor, personal)),
    current_ontology_identity(Ns, Anchor),
    findall(Human, human_user_owner(Human), [Owner]).
personal_agent_query(personal_agent_owner(_)).
personal_agent_query(space_location(personal, _)).
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
attribute(controller_reset_settings(_,_,_),label,<<"Repair VR controller settings">>).
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
