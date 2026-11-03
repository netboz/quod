from pathlib import Path
import re
r=Path('/home/yan/src/quod_worktrees/pearl-stone')
p=r/'priv/ontologies/common_predicates.pl';s=p.read_text();s=s.replace('append(LabelCodes,[46,10],Codes), binary_codes(Text,LabelCodes),\n    scene_vocabulary(Ns,A), in_ontology(Ns,A,limit(<<"label">>,Max)),\n    shorten(Text,Max,Label).','append(LabelCodes,[46,10],Codes), binary_codes(Label,LabelCodes).')
s=s[:s.index('\n%% Shared display-text shortening;')]+ '\n'
s=s.replace('%% The ordinary view and portable exposure receipt use one projection. Budget\n%% comes from the pinned scene policy; there is no recursion/depth constant.','%% The ordinary view and portable exposure receipt use one projection.\n%% Exact ancestry detects cycles; the proof owner admits resource use.')
s=s.replace('    in_ontology(Ns,A,limit(<<"scene">>,Allowance)),\n    integer(Allowance), Allowance >= 0,\n','').replace('role(physical,World),Allowance,_,Parts,Exposures)','role(physical,World),Parts,Exposures)')
s=s.replace('space_scene_parts([],_,_,_,_,_,Remaining,Remaining,[],[]).','space_scene_parts([],_,_,_,_,_,[],[]).').replace('                  Available,Remaining,Parts,Exposures) :-\n    (Available > 0 -> Next is Available - 1\n    ; fail_with_reason(space_exposure_allowance)),','                  Parts,Exposures) :-').replace('Placed = [], Current = [], After = Next','Placed = [], Current = []').replace('Occurrence,NextRole,Next,After,','Occurrence,NextRole,').replace('Parent,Role,After,Remaining,Tail,Others)','Parent,Role,Tail,Others)')
s=s.replace('                       Available,Remaining,Local,Children,Exposures,Frame,Subjects,Status) :-','                       Local,Children,Exposures,Frame,Subjects,Status) :-').replace('Status = cycle, Remaining = Available, Children = []','Status = cycle, Children = []').replace('Occurrence,Role,Available,Remaining,Children,Exposures)','Occurrence,Role,Children,Exposures)').replace('space_occurrence_model(Model,_,_,_,_,_,Available,Available,Model,[],[],none,[],model)','space_occurrence_model(Model,_,_,_,_,_,Model,[],[],none,[],model)')
p.write_text(s)
p=r/'priv/ontologies/gui_scene.pl';s=p.read_text();a=s.index('%% --- the bounds');b=s.index('%% --- a descriptor',a);s=s[:a]+s[b:];s=s.replace('rendering_query(limit(_, _)).\n','').replace('%%   limit(What, Max)                   the bound a descriptor may not exceed\n','');s=s.replace('bounded scene tree','scene tree').replace('one of the bounded geometries','one of the supported geometries').replace('a bounded list with distinct ids','a list with distinct ids').replace('Seven bounded parameterized shapes','Parameterized shapes').replace('every part is present, declared, and within bounds.','every part is present and conforms to its declared type.')
s=re.sub(r'bounded_text\((\w+), <<"(?:mark_id|label|ontology)">>\)',r'scene_text(\1)',s)
s=s.replace('    limit(<<"extent">>, Max),\n    Extent =< Max,\n','').replace('integer(Scale), Scale > 0, limit(<<"mesh_scale">>, MaxScale), Scale =< MaxScale,','integer(Scale), Scale > 0,')
s=re.sub(r'    mesh_extent\([^\n]+\),\n','',s).replace('    limit(<<"extent">>,Far), Distance+Retention =< Far,\n','')
s=re.sub(r'resource\((\w+),\s*<<"mesh_\w+">>\)',r'resource(\1)',s)
a=s.index('resource(Allowed, Name) :-');b=s.index('%% These two shapes',a);s=s[:a]+'''%% Each signed appearance may supply an explicit allocation. There is no
%% second global ceiling over the resource owner's authored allowance.
resource(unlimited).
resource(Allowed) :- integer(Allowed), Allowed > 0.

'''+s[b:]
a=s.index('offset(V) :-');b=s.index('\nturn(V)',a);s=s[:a]+'offset(V) :- integer(V).\n'+s[b:]
a=s.index('bounded_text(Text, What) :-');b=s.index('%% --- a scene',a);s=s[:a]+'scene_text(Text) :- binary_codes(Text, [_|_]).\n\n'+s[b:]
s=s.replace('a bounded list of well-formed marks','a list of well-formed marks').replace('    limit(<<"scene">>, Max),\n','').replace('    (Count =< Max -> true ; fail_with_reason(scene_mark_allowance(Count,Max))),\n','');p.write_text(s)
p=r/'priv/ontologies/gui_tools.pl';s=p.read_text().replace('lens_query(lens_limit(_, _)).\n','');a=s.index('%% --- the bounds');b=s.index('%% --- looking',a);s=s[:a]+s[b:];s=s.replace('the bounded list of descriptors','the list of descriptors').replace('    shorten(Text, Short),\n','').replace('label(Short, <<"above">>)','label(Text, <<"above">>)');a=s.index('satisfied(within(What), Rows) :-');b=s.index('%% An absent',a);s=s[:a]+s[b:];a=s.index('%% A label is display text, not an identity');b=s.index('%% Source is a textual encoding',a);s=s[:a]+s[b:];s=s.replace('requires(<<"reach_columns">>, within(<<"marks">>)).\n','')
s=s.replace('%% A bounded graphical encoding','%% A graphical encoding').replace('    append(CN, IN, Nodes), length(Nodes, Count), lens_limit(<<"marks">>, Limit),\n    (Count =< Limit -> true ; fail_with_reason(workbench_limit(marks, Count, Limit))),','    append(CN, IN, Nodes),').replace('workbench_links(PM, Nodes, Ns, A, 0, Links), append(NodeMarks, Links, Marks),\n    length(Marks, MarkCount),\n    (MarkCount =< Limit -> true ; fail_with_reason(workbench_limit(marks, MarkCount, Limit))).','workbench_links(PM, Nodes, Ns, A, 0, Links), append(NodeMarks, Links, Marks).').replace("'$quod_program_source'([Local], Text), shorten(Text, Label)","'$quod_program_source'([Local], Label)").replace('%% Presentation spacing accommodates the existing bounded native captions.','%% Presentation spacing is independent of source identity and label length.');p.write_text(s)
p=r/'priv/ontologies/quod_gui.pl';s=p.read_text().replace('gui_attribute(text_box, max_bytes, nonnegative_integer, default(4096)).','gui_attribute(text_box, max_bytes, nonnegative_integer, optional).');s=s.replace('gui_properties([property(Key, Default) | Contract], Attributes, [property(Key, Value) | Properties]) :-','''gui_properties([property(Key, optional) | Contract], Attributes, Properties) :-
    \\+ member(attribute(Key, _), Attributes), !,
    gui_properties(Contract, Attributes, Properties).
gui_properties([property(Key, Default) | Contract], Attributes, [property(Key, Value) | Properties]) :-''');s=s.replace('    member(property(max_bytes, Max), Properties), Length =< Max,','    (member(property(max_bytes, Max), Properties) -> Length =< Max; true),');p.write_text(s)
p=r/'priv/ontologies/lobby_worlds.pl';s=p.read_text();a=s.index('%% Allocate within the selected renderer');b=s.index('%% Viewing policy',a);s=s[:a]+'''%% Visual demand uses the existing finite viewing window and physical resource
%% admission. No independent default presentation quota is imposed on it.
world_render_resources(resources(unlimited,unlimited,unlimited,unlimited,unlimited)).

'''+s[b:];p.write_text(s)
p=r/'client/src/marks.js';s=p.read_text().replace(".map(n => whole(n, 'terrain allowance'))",".map(allowance)").replace(".map(n => whole(n, 'mesh allowance'))",".map(allowance)");idx=s.index('function readTerrain(');s=s[:idx]+'''function allowance(term) {
  return term?.type === 'atom' && term.value === 'unlimited' ? Infinity : whole(term, 'resource allowance')
}

'''+s[idx:];p.write_text(s)
p=r/'client/src/glb-profile.js';s=p.read_text().replace('allowed.every(n => Number.isSafeInteger(n) && n > 0)','allowed.every(n => n === Infinity || Number.isSafeInteger(n) && n > 0)');p.write_text(s)
p=r/'client/src/voxel-profile.js';s=p.read_text().replace('allowed.every(n => Number.isSafeInteger(n) && n >= 0)','allowed.every(n => n === Infinity || Number.isSafeInteger(n) && n >= 0)');p.write_text(s)
p=r/'src/quod_voxel.erl';s=p.read_text().replace('        true = allowance(Maximum),\n        Add = fun','        true = Maximum =:= unlimited orelse allowance(Maximum),\n        Add = fun');s=s.replace('charge(_,Actual,Limit) when Actual =< Limit -> ok;','charge(_,_,unlimited) -> ok;\ncharge(_,Actual,Limit) when Actual =< Limit -> ok;');p.write_text(s)
p=r/'src/quod_physics.erl';s=p.read_text().replace('                true = is_integer(L) andalso L >= 0,\n                case A =< L of','                true = L =:= unlimited orelse (is_integer(L) andalso L >= 0),\n                case L =:= unlimited orelse A =< L of');p.write_text(s)
