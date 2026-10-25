%% A second domain exercises the exact same discovery, form and signed path.
isa(note, thing).
have_attribute(note,name,binary,default(<<"Note">>)).
class_permission(note,create,allow).
class_permission(note,rename,allow).
class_eidolon(note,operation(class),create,recipe(Ns,A,note_create)) :- current_ontology_identity(Ns,A).
class_eidolon(note,operation(instance),rename,recipe(Ns,A,note_rename)) :- current_ontology_identity(Ns,A).
eidolon(note_create,subject(ontology_ref(Ns,A),class(note)),operation(note_create)) :- current_ontology_identity(Ns,A).
eidolon(note_rename,subject(ontology_ref(Ns,A),instance(Id)),operation(note_rename(Id))) :-
    current_ontology_identity(Ns,A), instance_of(note,Id).
instance_of(quod:gui:form,note_create).
instance_of(quod:gui:form,note_rename(Id)) :- instance_of(note,Id).
instance_of(quod:gui:text_box,note_name).
instance_of(quod:gui:button,note_save).
attribute(note_create,label,<<"Create note">>).
attribute(note_rename(_),label,<<"Rename note">>).
attribute(note_name,label,<<"Note name">>).
attribute(note_name,required,true).
attribute(note_save,label,<<"Save note">>).
gui_children(note_create,[note_name,note_save]).
gui_children(note_rename(_),[note_name,note_save]).
gui_initial(note_create,note_name,<<"Note">>).
gui_initial(note_rename(Id),note_name,Name) :- attribute(Id,name,Name).
gui_form(note_create,[field(note_name,Name)],submit(note_save,
    with_build_plan([attribute(name,Name)],assert(instance_of(note,Id))),
    operation(create([attribute(name,Name)]),[result(note,entity_ref(Ns,A,Id))]))) :- current_ontology_identity(Ns,A).
gui_form(note_rename(Id),[field(note_name,Name)],submit(note_save,
    note_rename(Id,Before,Name),operation(rename(Name),[]))) :- attribute(Id,name,Before).
note_rename(Id,Before,Name) :-
    operation_authorized(instance(Id),rename(Name)),
    transaction((retract(attribute(Id,name,Before)),assertz(attribute(Id,name,Name)))).
