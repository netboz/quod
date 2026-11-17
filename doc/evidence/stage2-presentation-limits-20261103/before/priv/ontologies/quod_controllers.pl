%% Shared device descriptions and binding policy; live devices remain transient.
acl_sovereign(quod:controllers).
can_invoke(Goal, _, _, _) :- controller_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- controller_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).
controller_query(isa(_, _)).
controller_query(class_eidolon(_, _, _, _)).
controller_query(eidolon(_, _, _)).
controller_query(Goal) :- public_source_query(Goal).
isa(device, thing).
%% Physical input descriptions are shared data, never a connected-device list.
isa(xr_controller, device).
isa(htc_vive_controller, xr_controller).
controller_query(controller_description(_, _)).
controller_query(controller_default(_)).
controller_query(controller_configuration(_, _)).
no_follow(controller_configuration/2).
no_follow(controller_roles/1).
no_follow(controller_overrides/2).
no_follow(controller_effective/3).
no_follow(controller_binding/1).
no_follow(controller_conflict/3).

controller_description(htc_vive_controller,
    controller([<<"htc-vive">>],
      [component(trigger,<<"xr-standard-trigger">>,trigger,[press,value]),
       component(grip,<<"xr-standard-squeeze">>,squeeze,[press]),
       component(pad,<<"xr-standard-touchpad">>,touchpad,[press,touch,axes2])],
      [target_ray,grip], Appearance)) :-
    class_eidolons([htc_vive_controller], input, solid,
        [eidolon(input,solid,recipe(Ns,A,Recipe))]),
    current_ontology_identity(Ns,A),
    eidolon(Recipe, class(htc_vive_controller), Appearance).

class_eidolon(htc_vive_controller,input,solid,recipe(Ns,A,vive_wand)) :-
    current_ontology_identity(Ns,A).
eidolon(vive_wand,class(htc_vive_controller),
    tracked_model(grip,asset(<<"bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94">>,
      <<"gltf2-static-v1">>,bounds(MinX,MinY,MinZ,59,23,106),
      resources(1114152,665696,17551,17344,37,1,4194304)))) :-
    MinX is -59, MinY is -70, MinZ is -117.

controller_default(settings([role(navigation,hand(left)),role(menu,hand(right))],vive_default,[])).
controller_bindings(vive_default,[
    bind(select,any,trigger,press_release,local(select)),
    bind(menu,menu,pad,radial(240),local(menu)),
    bind(drive,navigation,pad,axes_while(grip),control(drive)),
    bind(snap,navigation,pad,sector(horizontal,500,grip),control(snap)),
    bind(teleport,navigation,pad,sector(forward,500,grip),control(teleport(500)))]).

controller_configuration(settings(Roles,Set,Overrides),mapping(1,Roles,Bindings,Descriptions)) :-
    term_variables(settings(Roles,Set,Overrides),[]),
    controller_roles(Roles), controller_bindings(Set,Defaults),
    controller_overrides(Overrides,Defaults), controller_effective(Defaults,Overrides,Bindings),
    \+ (member(B,Bindings), \+ controller_binding(B)),
    \+ (member(B,Bindings),member(C,Bindings),B \== C,controller_conflict(B,C,Roles)),
    member(bind(select,_,_,press_release,local(select)),Bindings),
    findall(profile(Class,Description),controller_description(Class,Description),Descriptions),
    Descriptions = [_|_].
controller_roles([role(navigation,hand(N)),role(menu,hand(M))]) :-
    member(N,[left,right,none]),member(M,[left,right,none]).
controller_overrides([], _).
controller_overrides([Override|Rest], Defaults) :-
    (Override = disable(Id); Override = replace(bind(Id,_,_,_,_))),
    member(bind(Id,_,_,_,_),Defaults),
    \+ (member(Other,Rest),(Other = disable(Id);Other = replace(bind(Id,_,_,_,_)))),
    controller_overrides(Rest,Defaults).
controller_effective([],_,[]).
controller_effective([B|Rest],Overrides,Bindings) :-
    B = bind(Id,_,_,_,_),
    (member(disable(Id),Overrides) -> Bindings = Tail
    ; (member(replace(Replacement),Overrides),Replacement = bind(Id,_,_,_,_) -> Current = Replacement
      ; Current = B), Bindings = [Current|Tail]),
    controller_effective(Rest,Overrides,Tail).
controller_role(R) :- member(R,[any,navigation,menu]).
controller_press(C) :- member(C,[trigger,grip,pad]).
controller_permille(N) :- integer(N),N > 0,N < 1000.
controller_binding(bind(select,R,C,press_release,local(select))) :- controller_role(R),controller_press(C).
controller_binding(bind(menu,R,pad,radial(N),local(menu))) :- controller_role(R),controller_permille(N).
controller_binding(bind(drive,R,pad,axes_while(C),control(drive))) :-
    member(R,[navigation,menu]),member(C,[trigger,grip]).
controller_binding(bind(snap,R,pad,sector(horizontal,N,C),control(snap))) :-
    controller_role(R),controller_permille(N),member(C,[trigger,grip]).
controller_binding(bind(teleport,R,pad,sector(forward,N,C),control(teleport(F)))) :-
    controller_role(R),controller_permille(N),member(C,[trigger,grip]),controller_permille(F).
controller_conflict(bind(_,R,C,G,_),bind(_,S,C,H,_),Roles) :-
    controller_roles_overlap(R,S,Roles),
    \+ controller_disjoint(G,H).
controller_conflict(bind(_,R,C,press_release,_),bind(_,S,_,G,_),Roles) :-
    controller_roles_overlap(R,S,Roles),
    (G = axes_while(C);G = sector(_,_,C)).
controller_roles_overlap(R,S,Roles) :-
    (R = any;S = any;member(role(R,Hand),Roles),member(role(S,Hand),Roles)).
controller_disjoint(axes_while(C),sector(_,_,C)).
controller_disjoint(sector(_,_,C),axes_while(C)).
controller_disjoint(sector(horizontal,_,_),sector(forward,_,_)).
controller_disjoint(sector(forward,_,_),sector(horizontal,_,_)).
