%% Generic source and inspection eidolons. Their target remains the owning ontology;
%% no source or class definitions are copied into this recipe ontology.
acl_sovereign(quod:prolog:eidolons).
can_invoke(Goal, _, _, _) :- prolog_eidolon_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- prolog_eidolon_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

prolog_eidolon_query(eidolon(_, _, _)).
prolog_eidolon_query(class_eidolon(_, _, _, _)).
prolog_eidolon_query(isa(_, _)).
prolog_eidolon_query(Goal) :- public_source_query(Goal).

isa(prolog_editor, eidolon).
isa(eidolon, thing).

eidolon(prolog_editor, subject(Target, Entity),
        workspace(Target, Entity, ontology_ref(Tools, ToolsAnchor), View)) :-
    Target = ontology_ref(_, _), term_variables(Target-Entity, []),
    Tools = <<"quod:prolog">>, Gui = <<"quod:gui">>,
    quod:root::system_ontology(Tools, ToolsAnchor),
    quod:root::system_ontology(Gui, GuiAnchor),
    Tools::(current_ontology_identity(Tools, ToolsAnchor),
            prolog_inspect(Target, identity, Target)),
    prolog_source_view(Target, ViewId),
    Gui::(current_ontology_identity(Gui, GuiAnchor), gui_view(ViewId, View)).

%% Root classifies system access before the target's ordinary owner path.
prolog_source_view(Target, View) :-
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(Target, Access)),
    !,
    prolog_access_view(Access, View).
prolog_source_view(Target, View) :-
    quod:root::system_ontology(<<"quod:prolog">>, Anchor),
    <<"quod:prolog">>::(current_ontology_identity(<<"quod:prolog">>, Anchor),
        prolog_inspect(Target, presentation, Mode)),
    prolog_access_view(Mode, View).

eidolon(Style, subject(Target, Target),
        lens_view(Target, Target, ontology_ref(Lens, Anchor), View, [Target])) :-
    inspection_lens(Style, View),
    Lens = <<"quod:lens">>,
    quod:root::system_ontology(Lens, Anchor),
    %% Selecting a recipe grants no source access, even before its lens opens.
    quod:root::system_ontology(<<"quod:prolog">>, ToolsAnchor),
    <<"quod:prolog">>::(current_ontology_identity(<<"quod:prolog">>, ToolsAnchor),
        prolog_inspect(Target, identity, Target)).

inspection_lens(policy, <<"ontology_policy">>).
inspection_lens(interfaces, <<"ontology_interfaces">>).
inspection_lens(routes, <<"ontology_routes">>).

prolog_access_view(editable, prolog_editor).
prolog_access_view(read_only, prolog_source).
