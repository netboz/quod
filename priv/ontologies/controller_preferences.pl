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
    lobby_vocabulary(Ns,A),Ns::(current_ontology_identity(Ns,A),Goal).
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
