from pathlib import Path
r=Path('/home/yan/src/quod_worktrees/pearl-stone')
p=r/'priv/ontologies/common_predicates.pl';s=p.read_text().replace('isa(ontology, thing).','isa(ontology, space).',1)
a=s.index('%% Predicate subjects are derived');b=s.index('\nclass_eidolon(Class, prolog',a)
s=s[:a]+'''%% Reflected instances are ordinary local terms. Their source catalogue remains
%% authoritative, including interpreted empty definitions; reads create no state.
isa(predicate, thing).
instance_of(predicate, predicate(Indicator)) :-
    ontology_predicates(Indicators), member(Indicator, Indicators).
ontology_predicates(Indicators) :-
    current_ontology_identity(Namespace, Anchor),
    quod:root::system_ontology(<<"quod:gui">>, ToolsAnchor),
    in_ontology(<<"quod:gui">>, ToolsAnchor,
        prolog_predicates(ontology_ref(Namespace, Anchor), Indicators)).

class_eidolon(predicate, prolog, source, recipe(Ns,A,predicate_source)) :-
    current_ontology_identity(Ns,A).
eidolon(predicate_source, subject(Target,predicate(Indicator)), View) :-
    instance_of(predicate,predicate(Indicator)),
    quod:root::system_ontology(<<"quod:gui">>,A),
    in_ontology(<<"quod:gui">>,A,
        eidolon(prolog_editor(Indicator),subject(Target,predicate(Indicator)),View)).
class_eidolon(predicate,Mode,solid,recipe(Ns,A,predicate_model)) :-
    member(Mode,[playing,edition]), current_ontology_identity(Ns,A).
entity_scene(predicate(Indicator),Mode,
        appearance(predicate(Indicator),solid,predicate(Indicator),Pose,Eidolons)) :-
    ontology_predicates(Indicators), predicate_position(Indicators,Indicator,0,Pose),
    entity_eidolons(predicate(Indicator),Mode,solid,Eidolons).
predicate_position([Indicator|_],Indicator,Index,transform(X,Y,0,0,0,0)) :-
    X is (Index mod 16) * 1200, Y is -(Index // 16) * 800.
predicate_position([_|Rest],Indicator,Index,Pose) :-
    Next is Index + 1, predicate_position(Rest,Indicator,Next,Pose).
eidolon(predicate_model,predicate(Indicator),
        [part(<<"predicate">>,box(800,500,200),transform(0,0,0,0,0,0),
              surface(<<"#6A90D9">>,0,700,0,[]),unlabelled,depicts_nothing)]) :-
    instance_of(predicate,predicate(Indicator)).

%% These are display members, never containing-space assignments or grants.
space_member(ontology_ref(Ns,A),entity_ref(Ns,A,predicate(Indicator))) :-
    current_ontology_identity(Ns,A), instance_of(predicate,predicate(Indicator)).
attribute(ontology_ref(Ns,A),transform,transform(0,0,0,0,0,0)) :- current_ontology_identity(Ns,A).
attribute(ontology_ref(Ns,A),exterior,contents) :- current_ontology_identity(Ns,A).
attribute(ontology_ref(Ns,A),dimensions,infinite) :- current_ontology_identity(Ns,A).
''' +s[b:]
s=s.replace('public_source_query(client_eidolon(_, _, _)).','public_source_query(client_eidolon(_, _, _)).\npublic_source_query(entity_scene(_, _, _)).')
p.write_text(s)
p=r/'priv/ontologies/gui_tools.pl';s=p.read_text();old='''eidolon(prolog_editor, subject(Target, Entity),
        workspace(prolog_editor, Target, Entity, ontology_ref(Tools, ToolsAnchor), View)) :-''';new='''eidolon(prolog_editor, Subject, View) :- eidolon(prolog_editor(all), Subject, View).
eidolon(prolog_editor(Selection), subject(Target, Entity),
        workspace(prolog_editor(Selection), Target, Entity, ontology_ref(Tools, ToolsAnchor), View)) :-
    (Selection == all -> true
    ; prolog_predicates(Target,Indicators), member(Selection,Indicators)),''';assert old in s;s=s.replace(old,new);p.write_text(s)
p=r/'client/godot/Core/Eidolons.cs';s=p.read_text();s=s.replace('    public Term? Predicate=>Exact.Name=="predicate_ref" ? Exact.Args[2] : null;\n','');a=s.index('        if(exact.Name=="predicate_ref")');b=s.index('        var o=exact.Require',a);s=s[:a]+s[b:];p.write_text(s)
p=r/'client/godot/Core/Scene.cs';s=p.read_text().replace(' or "predicate_ref"','');p.write_text(s)
p=r/'client/godot/EidolonPanel.cs';s=p.read_text().replace('        source.SubjectSelected+=s=>Open(session,accounts,store,s);\n','').replace('            : Current.Predicate is {} predicate ? "Predicate · "+predicate.Args[0]+"/"+predicate.Args[1]\n','').replace('exact.Name is "ontology_ref" or "predicate_ref"','exact.Name=="ontology_ref"').replace('Term.Call("workspace",Term.Atom("prolog_editor"),a[0],a[1],a[2],a[5])','Term.Call("workspace",Term.Call("prolog_editor",Term.Atom("all")),a[0],a[1],a[2],a[5])');p.write_text(s)
p=r/'client/godot/SourcePanel.cs';s=p.read_text().replace('    string? boundPredicate;','    string selectionBinding="all";').replace('    public event Action<Term>? SubjectSelected;\n','')
s=s.replace('        if(!nextLens && a[0].Name!="prolog_editor")throw new FormatException("Unsupported workspace controller.");','        string nextBinding=nextLens ? "all" : a[0].Require("prolog_editor",1)[0].ToString();')
s=s.replace('        if(tool.Namespace!=choice.Recipe.Namespace || tool.Anchor!=choice.Recipe.Anchor)throw new FormatException("Representation names another recipe owner.");\n','')
s=s.replace('        string? nextPredicate=subject.Predicate?.ToString();\n        if(scope!=nextScope||boundPredicate!=nextPredicate){scope=nextScope;selected=nextPredicate??"all";draft=null;}\n        boundPredicate=nextPredicate;','        if(scope!=nextScope||selectionBinding!=nextBinding){scope=nextScope;selected=nextBinding;draft=null;}\n        selectionBinding=nextBinding;')
a=s.index('            if(i>0&&Catalogue.GetItemMetadata');b=s.index('\n        };',a)
s=s[:a]+'''            if(selectionBinding!="all")return;
            selected=i==0 ? "all" : catalogue[(int)i-1].ToString();draft=null;Run(()=>Read(false));'''+s[b:]
s=s.replace('boundPredicate!=null','selectionBinding!="all"')
s=s.replace('            Catalogue.SetItemMetadata(Catalogue.ItemCount-1,next.Items.Any(c=>c.ToString()==indicator.ToString()));\n','')
s=s.replace('Catalogue.Disabled=!authorized||busy','Catalogue.Disabled=selectionBinding!="all"||!authorized||busy')
p.write_text(s)
