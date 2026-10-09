%% One generic code-editing eidolon. Its target remains the owning ontology;
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
    prolog_source_view(Target, ViewId),
    Gui::(current_ontology_identity(Gui, GuiAnchor), gui_view(ViewId, View)).

%% Root classifies system access before the target's ordinary owner path.
prolog_source_view(Target, View) :-
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(Target, Access)),
    !,
    prolog_access_view(Access, View).
prolog_source_view(ontology_ref(Namespace, Anchor), prolog_editor) :-
    Namespace::current_ontology_identity(Namespace, Anchor).

prolog_access_view(editable, prolog_editor).
prolog_access_view(read_only, prolog_source).
