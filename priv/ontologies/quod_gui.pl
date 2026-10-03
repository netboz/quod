%% Shared semantic GUI vocabulary. A proof workspace is the first composite
%% form; its adapter reuses the existing cursor controls, never another executor.
acl_sovereign(quod:gui).
can_invoke(Goal, _, _, _) :- gui_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- gui_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

gui_query(gui_view(_, _)).
gui_query(isa(_, _)).

isa(gui_component, thing).
isa(container, gui_component).
isa(form, container).
isa(editor, gui_component).
isa(input, gui_component).
isa(choice, gui_component).
isa(bindings, gui_component).
isa(button, gui_component).
isa(proof_workspace, form).
isa(code_workspace, form).

%% Stable component roles bind local input and cursor results. Descriptors are
%% ground values, not suspended Prolog variables awaiting keyboard events.
gui_view(proof_console,
    form(<<"Prolog console">>,
         [editor(goal, <<"Prolog goal">>), bindings(results, <<"Bindings">>),
          button(run, <<"Run">>), button(next, <<"Next solution">>),
          button(accept, <<"Accept solution">>), button(stop, <<"Stop">>), button(resolve, <<"Check saved outcome">>)])).

gui_view(prolog_editor,
    form(<<"Prolog code">>,
         [choice(predicate, <<"Predicate">>), input(new_predicate, <<"New predicate (name/arity)">>),
          editor(source, <<"Source code">>),
          bindings(results, <<"Edit result">>), button(run, <<"Preview changes">>),
          button(accept, <<"Save changes">>), button(stop, <<"Cancel preview">>), button(create, <<"Add predicate">>),
          button(resolve, <<"Check saved outcome">>)])).
