%% One generic code-editing eidolon. Its target remains the owning ontology;
%% no source or class definitions are copied into this recipe ontology.
acl_sovereign(quod:prolog:eidolons).
can_invoke(Goal, _, _, _) :- prolog_eidolon_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- prolog_eidolon_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

prolog_eidolon_query(eidolon(_, _, _)).
prolog_eidolon_query(class_eidolon(_, _, _, _)).
prolog_eidolon_query(isa(_, _)).

isa(prolog_editor, eidolon).
isa(eidolon, thing).

eidolon(prolog_editor, subject(Target, Entity),
        workspace(Target, Entity, ontology_ref(Tools, ToolsAnchor), View)) :-
    Target = ontology_ref(_, _), term_variables(Target-Entity, []),
    Tools = <<"quod:prolog">>, Gui = <<"quod:gui">>,
    quod:root::system_ontology(Tools, ToolsAnchor),
    quod:root::system_ontology(Gui, GuiAnchor),
    Gui::(current_ontology_identity(Gui, GuiAnchor), gui_view(prolog_editor, View)).
