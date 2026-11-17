using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Explicit signed software phase. Native Controls receive software pointers;
// this method is never used by a human/native headset run.
public partial class ExportChecks
{
    async Task Stage2()
    {
        await Press("create-key");await Press("connect");
        Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"Stage2 fresh signed fixture network");
        await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true && State["operation_available"]?.GetValue<bool>()==true);
        var session=app.ActiveSession;var accounts=app.ActiveAccounts;var human=accounts.Human!;
        if(System.Environment.GetEnvironmentVariable("STAGE2_SUBJECT_ONLY")=="1"){await Stage2Subject();return;}
        var original=State["current_location"]!.ToString();string assignment=State["assignment_revision"]!.ToString();
        var subject=accounts.Setup!.Require("account",6)[2];var target=Actor.FromTerm(subject);
        var reply=await session.Read(human,SignedSession.ViewGoal(target,Term.Call("entity_eidolons",Term.Parse(target.InstanceText.TrimEnd('.')),Term.Variable("Choices"))),CancellationToken.None);
        var offered=Json.Binding(reply,"Choices").Items;
        Check(offered.Any(x=>x.Require("eidolon",3)[1].Name=="contents") && offered.Any(x=>x.Require("eidolon",3)[0].Name=="operation"),"actual same selected space authors contents and operation recipes");
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);gui.Surface.GuiEmbedSubwindows=true;
        async Task Pixel(Vector2 pixel){gui.Move(pixel);await Frame();gui.Press();await Frame();gui.Release();await Frame();Check(gui.Captures==0,"one software native-Control gesture retires capture");}
        async Task Click(Control target){
            var installed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            SpatialGui.Reveal(target,()=>GodotObject.IsInstanceValid(target),()=>installed.TrySetResult());
            await installed.Task.WaitAsync(TimeSpan.FromSeconds(10));
            if(!target.IsVisibleInTree() || !new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(target.GetGlobalRect()))Console.WriteLine("STAGE2_PRIVATE_TARGET "+target.Name+" "+target.GetGlobalRect()+" surface="+gui.Surface.Size);
            Check(target.IsVisibleInTree() && new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(target.GetGlobalRect()),"native target is reachable in the actual shared viewport");
            await Pixel(target.GetGlobalRect().GetCenter());
        }
        IEnumerable<Node> Descendants(Node n){foreach(Node c in n.GetChildren(true)){yield return c;foreach(var d in Descendants(c))yield return d;}}
        async Task Select(OptionButton select,int index){
            await Click(select);await Frame();var popup=select.GetPopup();
            Check(popup.Visible && new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(new Rect2(popup.Position,popup.Size)),"actual representation/catalogue popup opens within the shared surface");
            popup.ScrollToItem(index);await Frame();
            var scroll=Descendants(popup).OfType<ScrollContainer>().Single(v=>v.IsVisibleInTree());
            var items=scroll.GetChildren(true).OfType<Control>().Single(c=>c.GetClass()=="PopupMenuItems");
            int font=popup.GetThemeFontSize("font_size","PopupMenu"),gap=popup.GetThemeConstant("v_separation","PopupMenu");
            float height=Math.Max(popup.GetThemeFont("font","PopupMenu").GetHeight(font),popup.GetThemeIcon("radio_checked","PopupMenu").GetHeight());
            int changed=0;void Selected(long value){if(value==index)changed++;}int before=select.Selected;select.ItemSelected+=Selected;
            try{await Pixel((Vector2)popup.Position+items.GlobalPosition+new Vector2(60,index*(height+gap)+gap+height/2));}finally{select.ItemSelected-=Selected;}
            Check(select.Selected==index && !popup.Visible && changed==(before==index&&!select.AllowReselect ? 0 : 1),"real popup item changes exactly once through the shared native GUI route");
        }
        await Click((Button)app.FindChild("location-operations",true,false));
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        pane.Changed+=()=>Console.WriteLine("STAGE2_PRIVATE_VIEW "+JsonSerializer.Serialize(new {status=pane.StatusText,available=pane.Available,selected=pane.Selected?.Caption,source=(pane.FindChild("source-tools",true,false) as SourcePanel)?.Status}));
        await Until(()=>pane.Available && pane.Operations.Available);
        var chooser=(OptionButton)pane.FindChild("representation-choices",true,false);var operations=pane.Operations;
        Check(pane.Current?.Exact.ToString()==subject.ToString(),"same exact selected subject exposes its authored representation chooser");
        Check(pane.Offered.Select(e=>e.Exact.ToString()).SequenceEqual(offered.Select(e=>e.ToString())),"chooser offers only the actual exact-subject authored choices");
        async Task Choose(string purpose,string style){int i=Array.FindIndex(pane.Offered,c=>c.Purpose.Name==purpose && c.Style==style);Check(i>=0,"requested representation is actually authored");await Select(chooser,i+1);}
        var form=operations.FormPanel;var draft=form.Draft;var submit=form.Input(operations.Current!.Form.Submit.ToString());
        int instructions=Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        var chosen=pane.Offered.Single(e=>e.Purpose.Name=="playing"&&e.Style=="wireframe");
        var direct=await session.Read(human,SignedSession.ViewGoal(target,chosen.Read(Term.Parse(target.InstanceText.TrimEnd('.')))),CancellationToken.None);
        Console.WriteLine("STAGE2_PRIVATE_READ "+direct.ToJsonString());
        Check(Json.Committed(direct) && Json.Binding(direct,"View").Name=="eidolon_scene","the actual selected recipe read uses its admitted modelling owner");
        await Choose("playing","wireframe");var preview=(ScenePanel)pane.FindChild("representation-scene",true,false);
        await Until(()=>preview.Visible && preview.SubjectIds(subject).Length==1);
        var occurrence=preview.SubjectIds(subject).Single();var corner=preview.WorldCorners(occurrence)[0];
        Check(preview.PickRay(corner+new Vector3(0,0,1000),Vector3.Forward)?.ToString()==subject.ToString(),"selected authored wireframe edge retains exact depicted identity through the existing scene picker");
        int rebuilt=preview.Rebuilt;var signed=(SignedView)typeof(EidolonPanel).GetField("representation",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!.GetValue(pane)!;
        for(int i=0;i<3;i++)await Renew(pane,"representation");
        Check(preview.Rebuilt==rebuilt,"unchanged chosen exterior renewals retain the same scene resources");
        await Choose("playing","contents");await Until(()=>preview.Visible && preview.Count==0);
        Check(pane.Current!.Exact.ToString()==subject.ToString(),"contents chooses the same exact subject without creating a containing assignment");
        var operation=pane.Offered.First(e=>e.Operation);await Choose("operation",operation.Style);
        Check(ReferenceEquals(form.Draft,draft) && ReferenceEquals(form.Input(operations.Current!.Form.Submit.ToString()),submit),"representation changes preserve the existing operation draft and native controls");
        Check(State["current_location"]!.ToString()==original && State["assignment_revision"]!.ToString()==assignment && State["pending"]!.GetValue<int>()==0 && instructions==Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length,"presentation alone produces no location edit, instruction or pending operation");
        await Choose("prolog","source");var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        await Until(()=>source.Content.Length>0 && source.CanEdit);
        var sourceForm=(FormPanel)source.FindChild("source-form",true,false);var editor=(TextEdit)sourceForm.Input("source")!;
        Check(editor.Editable,"actual owner-authorized source representation provides an editable native control");
        if(System.Environment.GetEnvironmentVariable("STAGE2_LAYOUT_BASELINE")=="1") {
            await Stage2Layout(gui,pane,sourceForm);return;
        }
        async Task EditText(string value){
            var changed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Changed()=>changed.TrySetResult();editor.TextChanged+=Changed;
            try{editor.SelectAll();editor.InsertTextAtCaret(value);await changed.Task.WaitAsync(TimeSpan.FromSeconds(10));}finally{editor.TextChanged-=Changed;}
        }
        int reads=source.SnapshotReads;var stored=File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"));
        for(int i=0;i<3;i++)await Renew(pane,"representation");
        Check(reads==source.SnapshotReads && stored.SequenceEqual(File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"))) && ReferenceEquals(editor,sourceForm.Input("source")),"unchanged source authorization retains snapshot/control/draft with zero local writes");
        ((LineEdit)sourceForm.Input("new_predicate")!).Text="stage2_note/1";await Click(sourceForm.Input("create")!);await source.Completion;
        await EditText("stage2_note(first).\n");
        Check(app.ActiveStore.Snapshot!.SourceDrafts.Values.Any(d=>d.Text==editor.Text && d.Baseline==""),"local dirty draft persists with its original exact predicate baseline");
        var indicator=Term.Call("/",Term.Atom("stage2_note"),Term.Number("1"));var tools=accounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        async Task<string> Saved()=>Json.Binding(await session.Read(human,SignedSession.ViewGoal(tools,Term.Call("prolog_source",human.Ontology,indicator,Term.Variable("Source"))),CancellationToken.None),"Source").TextValue;
        // Hold one actual transport continuation, replace the representation,
        // then release it onto Godot's original executor. No reply is invented.
        var context=SynchronizationContext.Current!;var held=new HeldContinuation(context);
        var runButton=sourceForm.Input("run")!;
        for(Node? n=runButton.GetParent();n!=null;n=n.GetParent())if(n is ScrollContainer scroll)scroll.EnsureControlVisible(runButton);
        await Frame();await Frame();gui.Move(runButton.GetGlobalRect().GetCenter());gui.Press();await Frame();
        SynchronizationContext.SetSynchronizationContext(held);
        try{gui.Release();}finally{SynchronizationContext.SetSynchronizationContext(context);}
        await held.Arrived.WaitAsync(TimeSpan.FromSeconds(10));
        var another=accounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        pane.Open(session,accounts,app.ActiveStore,another.Ontology);await Until(()=>pane.Available);await Choose("prolog","source");
        var scopeField=typeof(SourcePanel).GetField("scope",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!;
        await Until(()=>source.Visible && ((string)scopeField.GetValue(source)!).Contains(another.Ontology.ToString()));
        held.Release();await source.Completion;
        var previewField=typeof(SourcePanel).GetField("preview",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!;
        Check(previewField.GetValue(source)==null && !source.CanEdit && source.Content.Length>0 && app.ActiveStore.Snapshot!.SourceDrafts.Values.Any(d=>d.Text=="stage2_note(first).\n"),"a completed compiler response continued after target replacement cannot install an old preview or clear its draft");
        if(System.Environment.GetEnvironmentVariable("STAGE2_RACE_BASELINE")=="1")throw new Exception("Expected old-owner race baseline unexpectedly passed.");
        pane.Open(session,accounts,app.ActiveStore,subject);await Until(()=>pane.Available);await Choose("prolog","source");await Until(()=>source.CanEdit);
        var retainedCatalogue=(OptionButton)sourceForm.Input("predicate")!;
        await Select(retainedCatalogue,Enumerable.Range(1,retainedCatalogue.ItemCount-1).Single(i=>retainedCatalogue.GetItemText(i)=="stage2_note/1"));await source.Completion;
        Check(source.Content=="stage2_note(first).\n","returning to the original exact predicate restores its separate dirty draft after a target switch");editor=(TextEdit)sourceForm.Input("source")!;
        await Click(sourceForm.Input("run")!);await source.Completion;
        Check(await Saved()=="" && !((Button)sourceForm.Input("accept")!).Disabled,"preview uses the existing proof owner and leaves source unchanged before Accept");
        var proof=(ProofPreview)typeof(SourcePanel).GetField("preview",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!.GetValue(source)!;
        bool expired=false;try{await session.Accept(proof with {Deadline=SignedSession.Now},CancellationToken.None);}catch(TimeoutException){expired=true;}
        Check(expired && app.ActiveStore.Snapshot!.Pending.Count==0 && await Saved()=="","locally expired Accept is provably unsent and leaves no pending work or commit");
        using(var cancel=new CancellationTokenSource()) {
            bool once=false;app.ActiveStore.DurabilityBoundary=boundary=>{if(!once && boundary=="after-rename"){once=true;cancel.Cancel();}};
            bool cancelled=false;try{await session.Accept(proof,cancel.Token);}catch(OperationCanceledException){cancelled=true;}finally{app.ActiveStore.DurabilityBoundary=null;}
            Check(once && cancelled && app.ActiveStore.Snapshot!.Pending.Count==0 && await Saved()=="","cancellation after durable journaling but before send removes only the provably unsent original");
        }
        await Click(sourceForm.Input("stop")!);await source.Completion;
        Check(await Saved()=="" && editor.Text=="stage2_note(first).\n","cancelled proof does not commit or discard the original local draft");
        await Click(sourceForm.Input("run")!);await source.Completion;await Click(sourceForm.Input("accept")!);await source.Completion;
        if(app.ActiveStore.Snapshot!.Pending.Any()){await Until(()=>!((Button)sourceForm.Input("resolve")!).Disabled);await Click(sourceForm.Input("resolve")!);await source.Completion;}
        Check((await Saved()).Contains("stage2_note(first)"),"explicit Accept commits the guarded edit through the actual same ontology owner");
        await Until(()=>source.CanEdit && source.Content.Contains("stage2_note(first)"));
        editor=(TextEdit)sourceForm.Input("source")!;
        await Click((Button)source.FindChild("source-discard",true,false));await source.Completion;
        await EditText("stage2_note(local).\n");
        Check(Json.Committed(await ExecuteComplete(session,app.ActiveStore,human,"transaction((retract(stage2_note(first)),assertz(stage2_note(concurrent)))).",CancellationToken.None)),"an independent current-owner edit creates a real stale-baseline race");
        await Until(()=>source.CanEdit && source.Content.Contains("stage2_note(local)"));
        await Click(sourceForm.Input("run")!);await source.Completion;
        Check((await Saved()).Contains("stage2_note(concurrent)") && ((Button)sourceForm.Input("accept")!).Disabled && editor.Text.Contains("stage2_note(local)"),"stale baseline refuses replacement while preserving the local draft without replay");
        await Click((Button)source.FindChild("source-discard",true,false));await source.Completion;
        Check(source.Content.Contains("stage2_note(concurrent)"),"explicit discard/reload adopts the current committed source");
        Check(Json.Committed(await ExecuteComplete(session,app.ActiveStore,human,"transaction((retract(stage2_note(concurrent)),assertz(stage2_note(clean_refresh)))).",CancellationToken.None)),"a real update changes committed clean source");
        await Until(()=>source.CanEdit);await Click((Button)source.FindChild("source-reload",true,false));await source.Completion;
        Check(source.Content.Contains("stage2_note(clean_refresh)"),"explicit reload replaces a clean baseline with current committed source");
        if(System.Environment.GetEnvironmentVariable("STAGE2_LAYOUT")=="1"){await Stage2Layout(gui,pane,sourceForm);return;}
        // A terminal reply whose local reconciliation fails remains the same
        // recoverable signed operation across a real store/session restart.
        string recoveryPath=System.IO.Path.Combine(profile,"source-recovery"),accountRecoveryPath=System.IO.Path.Combine(profile,"source-account-recovery");
        using(var recoveryStore=new LocalStore(recoveryPath)) {
            recoveryStore.Create(session.Key.Payload());var savedState=app.ActiveStore.Snapshot!;
            recoveryStore.Update(s=>{s.Accounts=new(savedState.Accounts);s.SourceDrafts=new(savedState.SourceDrafts);});
            using var recovery=new SignedSession(session.Key,recoveryStore,new Transport(session.Transport.Origin.ToString(),app.ActiveStore.Snapshot!.CaFile));
            await recovery.Authenticate(CancellationToken.None);
            pane.Open(recovery,accounts,recoveryStore,human.Ontology);await Until(()=>pane.Available);await Choose("prolog","source");await Until(()=>source.CanEdit);
            var predicates=(OptionButton)sourceForm.Input("predicate")!;
            await Select(predicates,Enumerable.Range(1,predicates.ItemCount-1).Single(i=>predicates.GetItemText(i)=="stage2_note/1"));await source.Completion;editor=(TextEdit)sourceForm.Input("source")!;
            await EditText("stage2_note(recovered).\n");await Click(sourceForm.Input("run")!);await source.Completion;
            bool reconciliationFault=false;
            recoveryStore.DurabilityBoundary=boundary=>{if(boundary=="before-rename" && recoveryStore.Snapshot!.Pending.Any()){reconciliationFault=true;throw new System.IO.IOException("Controlled source reconciliation durability failure.");}};
            await Click(sourceForm.Input("accept")!);await source.Completion;
            bool committed=(await Saved()).Contains("stage2_note(recovered)");
            Console.WriteLine("STAGE2_PRIVATE_RECOVERY "+JsonSerializer.Serialize(new {reconciliationFault,committed,pending=recoveryStore.Snapshot!.Pending.Count}));
            Check(recoveryStore.Snapshot!.Pending.Count==1 && committed,"a real committed edit with unresolved local acknowledgement retains the exact signed outcome and submitted draft");
            pane.Cancel();await pane.Completion;
        }
        using(var recoveredStore=new LocalStore(recoveryPath)) {
            var originalWork=recoveredStore.Snapshot!.Pending.Single();
            Check(originalWork.SourceDraft?.Text=="stage2_note(recovered).\n","reopened original work retains exact submitted draft identity");
            var newer=new SourceDraft(originalWork.SourceDraft!.Baseline,"stage2_note(newer_local).\n");
            recoveredStore.Update(s=>s.SourceDrafts[originalWork.Flow]=newer);
            // Retain the actual durable pre-resolution state for a separate
            // ordinary Main.Connect/Accounts.Discover process incarnation.
            System.IO.Directory.CreateDirectory(accountRecoveryPath,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
            File.Copy(System.IO.Path.Combine(recoveryPath,"active.json"),System.IO.Path.Combine(accountRecoveryPath,"active.json"));
            await File.WriteAllTextAsync(Env("M1B_RESULT")+".recovery.json",JsonSerializer.Serialize(new {workId=originalWork.Id,flow=originalWork.Flow,newer=newer.Text,human=human.Entity.ToString(),instructions=Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length}));
            using var recovered=new SignedSession(session.Key,recoveredStore,new Transport(session.Transport.Origin.ToString(),app.ActiveStore.Snapshot!.CaFile));
            await recovered.Authenticate(CancellationToken.None);pane.Open(recovered,accounts,recoveredStore,human.Ontology);await Until(()=>pane.Available);await Choose("prolog","source");await Until(()=>source.Visible && source.Status.Contains("pending") && !source.CanEdit);
            Check(source.Status.Contains("pending") && !source.CanEdit,"pending reopen explicitly withholds new edits and offers original outcome recovery");
            await Click(sourceForm.Input("resolve")!);await source.Completion;
            Check(recoveredStore.Snapshot!.Pending.Count==0 && recoveredStore.Snapshot.SourceDrafts[originalWork.Flow]==newer && (await Saved()).Contains("stage2_note(recovered)"),"Resolve recovers the original commit without replay and cannot erase a newer draft at the same key");
            await Click((Button)source.FindChild("source-reload",true,false));await source.Completion;editor=(TextEdit)sourceForm.Input("source")!;
            recoveredStore.DurabilityBoundary=boundary=>{if(boundary=="before-rename")throw new System.IO.IOException("Controlled typed draft durability failure.");};
            await EditText("stage2_note(unsaved_typing).\n");
            Check(source.Status.Contains("typed draft durability failure") && editor.Text.Contains("unsaved_typing"),"native typing reports its real storage failure while retaining the visible draft");
            await EditText("stage2_note(still_unsaved).\n");Check(source.Status.Contains("Reopen and verify"),"write-faulted storage remains fenced after the typed-draft failure");
            pane.Cancel();await pane.Completion;
        }
        var system=accounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        await Click((Button)app.FindChild("create-operations",true,false));
        var storage=(OptionButton)operations.FindChild("operation-storage",true,false);
        int systemIndex=Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==system.Namespace+" @ "+system.Anchor);
        await Select(storage,systemIndex);await operations.Completion;
        await Click((Button)pane.FindChild("inspect-subject-storage",true,false));await Until(()=>pane.Available);
        Check(pane.Current!.Exact.ToString()==system.Ontology.ToString(),"actual native catalogue selection opens that exact ontology without requiring a class operation");
        await Choose("prolog","source");await Until(()=>source.Content.Contains("gui_"));editor=(TextEdit)sourceForm.Input("source")!;
        Check(!source.CanEdit && !((TextEdit)sourceForm.Input("source")!).Editable,"system ontology source stays read only despite discovered editor associations");
        var readonlyChoice=pane.Selected!;var readonlySubject=pane.Current!;
        var validWorkspace=Json.Binding(await session.Read(human,SignedSession.ViewGoal(system,readonlyChoice.Read(readonlySubject.Local)),CancellationToken.None),"View");
        var workspaceArgs=validWorkspace.Require("workspace",5);var invalidWorkspace=Term.Call("workspace",workspaceArgs[0],workspaceArgs[1],workspaceArgs[2],workspaceArgs[3],Term.Atom("malformed_workspace"));
        string priorContent=source.Content;var priorEditor=sourceForm.Input("source");int refusals=0;
        for(int i=0;i<2;i++)try{source.Install(session,accounts,app.ActiveStore,readonlySubject,readonlyChoice,invalidWorkspace);}catch(FormatException){refusals++;}
        source.Install(session,accounts,app.ActiveStore,readonlySubject,readonlyChoice,validWorkspace);await source.Completion;
        Check(refusals==2 && source.Content==priorContent && ReferenceEquals(priorEditor,sourceForm.Input("source")) && !source.CanEdit,"malformed repeated descriptors cannot install authorization or poison the existing valid read-only workspace");
        string readonlyScope=(string)typeof(SourcePanel).GetField("scope",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!.GetValue(source)!;
        string committedReadOnly=source.Content;var kept=new SourceDraft(committedReadOnly,"not_committed_local_draft.");
        app.ActiveStore.Update(s=>s.SourceDrafts[readonlyScope+"\nall"]=kept);
        await Click((Button)source.FindChild("source-reload",true,false));await source.Completion;
        Check(source.Content==committedReadOnly && app.ActiveStore.Snapshot!.SourceDrafts[readonlyScope+"\nall"]==kept,"read-only source shows committed text while preserving the separate local dirty draft");
        await Choose("inspection","policy");await Until(()=>source.Content.Length>0 && source.Status.StartsWith("Authorized inspection"));
        string policy=await session.ReadSource(human,SignedSession.ViewGoal(tools,Term.Call("view",Term.Text("ontology_policy"),Term.List(system.Ontology),Term.Variable("Rows"))),"Rows",CancellationToken.None);
        Check(source.Content==policy && !source.Content.StartsWith("source_chunk") && !source.CanEdit,"authored inspection lens uses the complete signed cursor UTF8 decoder and remains read only");
        await Transition(new(){["source_access"]="deny"});await Until(()=>source.Content.Length==0);
        Check(!source.CanEdit,"real source permission revocation withdraws source and editor authority");
        await Transition(new(){["source_access"]="restore"});pane.Open(session,accounts,app.ActiveStore,system.Ontology);await Until(()=>pane.Available);await Choose("prolog","source");await Until(()=>source.Content.Length>0);
        var wrong=system with {Anchor=Identity.Encode(new byte[32])};pane.Open(session,accounts,app.ActiveStore,wrong.Ontology);await Until(()=>pane.StatusText.StartsWith("Unavailable"));
        Check(!pane.Available && source.Content.Length==0,"wrong-anchor discovery cannot publish another ontology's content");
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0,"Stage2 consumers retire with the signed session");
        await File.WriteAllTextAsync(Env("M1B_RESULT")+".stage1.json",JsonSerializer.Serialize(new {passed=true,checks,physical=false}));
        Console.WriteLine("STAGE2_RESTART");Console.Out.Flush();await app.CloseApplication();
    }
    async Task Stage2Recover()
    {
        var expected=JsonNode.Parse(await File.ReadAllTextAsync(Env("M1B_RECOVERY_META")))!;
        Check(app.ActiveStore.Snapshot!.Pending.Single().Id==Json.S(expected,"workId"),"new Main incarnation loads the exact retained unresolved source request");
        await Press("connect");await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
        var accounts=app.ActiveAccounts;var session=app.ActiveSession;var human=accounts.Human!;
        Check(human.Entity.ToString()==Json.S(expected,"human") && app.ActiveStore.Snapshot!.Pending.Count==0,"ordinary Connect/Discover resolves and retires the original source work without an editor-specific recovery path");
        Check(app.ActiveStore.Snapshot!.SourceDrafts[Json.S(expected,"flow")].Text==Json.S(expected,"newer"),"ordinary account recovery cannot erase a newer draft belonging to the same source key");
        Check(Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length==expected["instructions"]!.GetValue<int>(),"ordinary reconnect performs no source write replay or new personal instruction");
        await Press("inspect");var pane=(EidolonPanel)app.FindChild("representations",true,false);await Until(()=>pane.Available);
        pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="prolog" && e.Style=="source"));var source=(SourcePanel)pane.FindChild("source-tools",true,false);await Until(()=>source.CanEdit);
        Check(source.Content.Contains("stage2_note(recovered)"),"same committed source is read back after ordinary account recovery");
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"ordinary reconnect consumers retire without retained sockets");
        var first=JsonNode.Parse(await File.ReadAllTextAsync(Env("M1B_RESULT")+".stage1.json"))!;
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks,prior_checks=first["checks"],physical=false}));Console.WriteLine("STAGE2_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task Stage2Subject()
    {
        var session=app.ActiveSession;var accounts=app.ActiveAccounts;var human=accounts.Human!;
        var response=await SpaceControl(new(){["stage2_ontology_mark"]=new JsonObject { ["Namespace"]=human.Namespace,["Anchor"]=human.Anchor }});
        var depicts=Term.Parse(Json.S(response,"depicts"));
        Term Mark(Term depiction)=>Term.Call("mark",Term.Text("ontology-pick"),Term.Text("box"),Term.List(Term.Call("f",Term.Text("width"),Term.Number("1000")),Term.Call("f",Term.Text("height"),Term.Number("1000")),Term.Call("f",Term.Text("depth"),Term.Number("1000"))),Term.Call("transform",Enumerable.Range(0,6).Select(_=>Term.Number("0")).ToArray()),Term.Call("surface",Term.Text("#6A90D9"),Term.Number("0"),Term.Number("900"),Term.Number("0"),Term.List()),Term.Atom("unlabelled"),depiction);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);scene.Apply(Term.List(Mark(depicts)));await Frame();
        var picked=scene.PickRay(new Vector3(0,0,1000),Vector3.Forward);
        Check(picked?.ToString()==human.Ontology.ToString(),"the existing authored ontology depiction decodes and picks the identical flat catalogue subject");
        var point=scene.Project("ontology-pick",Vector3.Zero)*scene.Size/(Vector2)scene.Viewport.Size;
        foreach(bool down in new[]{true,false})scene._GuiInput(new InputEventMouseButton { ButtonIndex=MouseButton.Left,Pressed=down,Position=point });
        var pane=(EidolonPanel)app.FindChild("representations",true,false);await Until(()=>pane.Available);
        Check(pane.Current?.Exact.ToString()==human.Ontology.ToString(),"actual scene press/release reaches Main's shared chooser with the catalogue ontology identity");
        var offered=pane.Offered.Select(e=>e.Exact.ToString()).ToArray();pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="prolog"));
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);await Until(()=>source.Content.Length>0);
        Check(source.CanEdit,"the picked owned ontology reaches its existing guarded source representation");
        pane.Open(session,accounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Available);
        Check(pane.Current!.Exact.ToString()==human.Ontology.ToString() && pane.Offered.Select(e=>e.Exact.ToString()).SequenceEqual(offered),"catalogue and mark use one exact-subject discovery and representation consumer");
        var changed=depicts.Args.ToArray();changed[0]=Term.Text("different-owner");
        var foreign=SceneMark.Decode(Term.List(Mark(Term.Call("depicts",changed)))).Single().Subject!;
        Check(foreign.Name=="entity_ref" && foreign.Args[2].ToString()==human.Ontology.ToString(),"mismatched-owner ontology data is not unwrapped into a forged flat subject");
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"ontology picking consumers retire normally");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks,physical=false}));Console.WriteLine("STAGE2_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task Stage2Contents()
    {
        var metadata=JsonNode.Parse(await File.ReadAllTextAsync(Env("M3_PHYSICS_META")))!;
        var human=Actor.FromTerm(Term.Parse(Json.S(metadata,"viewer")));var outer=Actor.FromTerm(Term.Parse(Json.S(metadata,"s0")));var leaf=Term.Parse(Json.S(metadata,"leaf"));
        using var identity=Identity.FromPayload(await File.ReadAllTextAsync(Env("M3_PHYSICS_KEY")));
        using var store=new LocalStore(profile+"-selected-contents");store.Create(identity.Payload());
        using var session=new SignedSession(identity,store,new Transport(Env("M3_NODE"),Env("M3_CA")));
        using var deadline=new CancellationTokenSource(TimeSpan.FromMinutes(3));await session.Authenticate(deadline.Token);
        // This existing M3 fixture has no GUI catalogue owner. Its actual
        // authored playing choices can be read without asking that absent
        // optional owner for unrelated Prolog representations.
        var choices=Json.Binding(await session.Read(human,SignedSession.ViewGoal(outer,Term.Call("entity_eidolons",Term.Parse(outer.InstanceText.TrimEnd('.')),Term.Atom("playing"),Term.Atom("contents"),Term.Variable("Choices"))),deadline.Token),"Choices");
        var choice=Eidolon.Decode(choices.ToString()).Single();
        var direct=await session.Read(human,SignedSession.ViewGoal(outer,choice.Read(Term.Parse(outer.InstanceText.TrimEnd('.')))),deadline.Token);
        Console.WriteLine("STAGE2_PRIVATE_CONTENTS_READ "+direct.ToJsonString());Check(Json.Committed(direct),"the selected authored contents recipe is admitted independently of unrelated optional representations");
        var scene=new ScenePanel();app.AddChild(scene);WorldProjection? projection=null;string? failure=null;bool transitionExpected=false;string? withdrawal=null;
        using var motion=new PhysicsInput(session,human);
        var changed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Notice(){var old=changed;changed=new(TaskCreationOptions.RunContinuationsAsynchronously);old.TrySetResult();}
        async Task Wait(Func<bool> condition){while(!condition()){if(failure!=null)throw new Exception(failure);await changed.Task.WaitAsync(deadline.Token);}}
        using var view=new SignedView(session,human,outer,"eidolon_scene",SignedSession.ViewGoal(outer,choice.Read(Term.Parse(outer.InstanceText.TrimEnd('.')))));
        int frames=0;var streamed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        view.Projection+=m=>{try{projection=scene.ApplyProjection(m,outer,human,ack=>_ = view.Send(ack));motion.Present(projection);}catch(Exception e){failure=e.Message;}Notice();};
        view.Message+=m=>{if(m["type"]?.ToString()=="simulation_frame"){try{if(scene.ApplyFrame(m,ack=>_ = view.Send(ack))){motion.Present(projection!);if(++frames>=3)streamed.TrySetResult();}}catch(Exception e){failure=e.Message;}Notice();}};
        view.Withdrawn+=reason=>{projection=null;scene.Withdraw();withdrawal=reason;if(!transitionExpected)failure=reason;Notice();};
        _=view.Start();await Wait(()=>projection!=null && scene.SubjectIds(leaf).Length==3);
        Check(scene.SubjectIds(leaf).Length==3,"the shared selected-representation consumer renders the existing three recursive independent appearances");
        // The retained native world can sleep. One ordinary signed fixture
        // drive supplies actual activity; idle silence is not lost credit.
        motion.Drive(.1,0,0);await motion.Completion;
        bool sustained=true;try{await streamed.Task.WaitAsync(TimeSpan.FromSeconds(10));}catch(TimeoutException){sustained=false;}
        motion.Drive(0,0,0);await motion.Completion;
        Check(sustained,"selected physical representation returns frame credit through the same view owner and continues beyond the initial delivery");
        int rebuilt=scene.Rebuilt;using(var probe=new System.Net.Sockets.TcpClient()) {
            await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),deadline.Token);using var stream=probe.GetStream();using var reader=new StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),deadline.Token);
            Check(JsonNode.Parse((await reader.ReadLineAsync(deadline.Token))!)!["ready"]!.GetValue<bool>(),"existing owner work observation is installed before unchanged selected-view renewals");
            for(int i=0;i<3;i++) {
                var received=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Projected(JsonNode _)=>received.TrySetResult();view.Projection+=Projected;
                try{await view.Renew();await received.Task.WaitAsync(deadline.Token);}finally{view.Projection-=Projected;}
            }
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),deadline.Token);
            var work=JsonNode.Parse((await reader.ReadLineAsync(deadline.Token))!)!;await File.WriteAllTextAsync(Env("M1B_RESULT")+".work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0 && scene.Rebuilt==rebuilt,"unchanged selected contents retain resources with zero watched history/install/write/sync work");
        }
        transitionExpected=true;await SpaceControl(new(){["mutate"]="source"});await Wait(()=>projection!=null && scene.Rebuilt>rebuilt);transitionExpected=false;
        Check(scene.SubjectIds(leaf).Length==3,"a real source update propagates without collapsing independent occurrences");
        var other=new ScenePanel();app.AddChild(other);var independent=Actor.FromTerm(Term.Parse(Json.S(metadata,"independent")));WorldProjection? otherProjection=null;int independentWithdrawals=0;
        using var independentView=new SignedView(session,human,independent,"world",SignedSession.ViewGoal(independent,Term.Call("client_world_view",Term.Parse(independent.InstanceText.TrimEnd('.')),Term.Atom("playing"),Term.List(),Term.Variable("View"))));
        independentView.Projection+=m=>{otherProjection=other.ApplyProjection(m,independent,human,ack=>_ = independentView.Send(ack));Notice();};
        independentView.Message+=m=>{if(m["frame"]!=null)other.ApplyFrame(m,ack=>_ = independentView.Send(ack));};
        independentView.Withdrawn+=_=>{independentWithdrawals++;otherProjection=null;other.Withdraw();Notice();};
        _=independentView.Start();await Wait(()=>otherProjection?.Sample!=null);string fence=otherProjection!.Sample!.Fence;
        transitionExpected=true;withdrawal=null;await SpaceControl(new(){["mutate"]="revoke"});
        using(var until=new CancellationTokenSource(TimeSpan.FromSeconds(30)))while(projection!=null || withdrawal?.StartsWith("Unavailable:")!=true)await changed.Task.WaitAsync(until.Token);
        var current=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Accepted(JsonNode _)=>current.TrySetResult();independentView.Projection+=Accepted;
        try{await independentView.Renew();await current.Task.WaitAsync(deadline.Token);}finally{independentView.Projection-=Accepted;}
        Check(otherProjection?.Sample?.Fence==fence && independentWithdrawals==0 && other.Count==0 && scene.Count==0,"dependency denial withdraws the selected consumer while a fresh accepted independent projection stays available");
        view.Dispose();await view.Completion;independentView.Dispose();await independentView.Completion;scene.Withdraw();other.Withdraw();scene.QueueFree();other.QueueFree();
        Check(SignedView.LiveSockets==0,"selected representation and independent view resources retire with their consumers");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks,physical=false}));Console.WriteLine("STAGE2_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task Stage2Layout(SpatialGui gui,EidolonPanel pane,FormPanel form)
    {
        var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        ((ScenePanel)app.FindChild("space-scene",true,false)).Hide();xr.PresentWorkspace(true);
        var reports=new List<object>();
        double Angle(double metres,double distance)=>2*Math.Atan(metres/(2*distance))*180/Math.PI;
        async Task Reveal(Control target){var installed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);SpatialGui.Reveal(target,()=>GodotObject.IsInstanceValid(target),()=>installed.TrySetResult());await installed.Task.WaitAsync(TimeSpan.FromSeconds(10));}
        bool Enclosed(Control target){var bounds=target.GetGlobalRect();if(!new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(bounds))return false;for(Node? n=target.GetParent();n!=null && n!=gui.Surface;n=n.GetParent())if(n is Control { ClipContents:true } clip && !clip.GetGlobalRect().Encloses(bounds))return false;return true;}
        foreach(int font in new[]{26,48,16}) {
            gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();
            foreach(float distance in new[]{2f,.6f,4f}) {
                xr.WorkspaceDistance(-100);xr.WorkspaceDistance(distance-.6f);await Frame();await Frame();
                var mesh=((QuadMesh)xr.GuiSurface.Mesh).Size;var target=form.Input("accept")!;
                await Reveal(target);
                var bounds=target.GetGlobalRect();var text=target.GetThemeFont("font").GetStringSize(((Button)target).Text,HorizontalAlignment.Left,-1,target.GetThemeFontSize("font_size"));
                reports.Add(new {font,distance,pixels=new[]{gui.Surface.Size.X,gui.Surface.Size.Y},mesh=new[]{mesh.X,mesh.Y},panel_degrees=Angle(mesh.X,distance),target=bounds.ToString(),native_text_box=new[]{text.X,text.Y},nominal_target_degrees=Angle(bounds.Size.Y/gui.Surface.Size.Y*mesh.Y,distance),nominal_text_box_degrees=Angle(text.Y/gui.Surface.Size.Y*mesh.Y,distance)});
                Check(Math.Abs(Angle(mesh.X,distance)-41.112090439)<.001 && bounds.Size.Y>=44,"the installed distance/text combination preserves central angular scale and its actual native action target");
            }
            var targets=new[]{"run","accept","stop","create","resolve"}.Select(role=>form.Input(role)!).Concat(new[]{(Control)pane.FindChild("source-reload",true,false),(Control)pane.FindChild("source-discard",true,false)});
            foreach(var target in targets) {
                await Reveal(target);
                Check(Enclosed(target),"every source action/reload/discard reflows inside its actual clipping viewports at font "+font);
                gui.Move(target.GetGlobalRect().GetCenter());await Frame();var hovered=gui.Surface.GuiGetHoveredControl();
                Check(hovered==target || hovered!=null && target.IsAncestorOf(hovered),"native hit testing reaches the displayed action without crossing a clipped owner at font "+font);
            }
        }
        var actions=new[]{"run","accept","stop","create","resolve"}.Select(r=>form.Input(r)!).ToArray();
        foreach(var target in actions) {
            await Reveal(target);
            Check(new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(target.GetGlobalRect()) && target.Size.Y>=44,"the actual shared workspace action remains reachable at the smallest supported font with a generous native target");
        }
        if(DisplayServer.GetName()!="headless") {
            string directory=Env("M4_MORNING_IMAGES");System.IO.Directory.CreateDirectory(directory);
            foreach(int font in new[]{26,48}) {
                gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();
                var primary=form.Input("accept")!;
                await Reveal(primary);await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
                Check(gui.Surface.GetTexture().GetImage().SavePng(System.IO.Path.Combine(directory,"source-"+font+".png"))==Error.Ok,"actual Stage2 shared workspace raster captured at font "+font);
                var editor=(TextEdit)form.Input("source")!;await Reveal(editor);
                Check(Enclosed(editor),"the actual code editor is enclosed by its clipping owners without shrinking its native text area");
                string text=editor.Text;var draft=form.Draft.ToDictionary(p=>p.Key,p=>p.Value);var profileBefore=File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"));
                gui.Move(editor.GetGlobalRect().GetCenter());gui.Press();gui.Release();await Frame();
                Check(editor.HasFocus() && gui.Captures==0 && editor.Text==text && form.Draft.OrderBy(p=>p.Key).SequenceEqual(draft.OrderBy(p=>p.Key)) && profileBefore.SequenceEqual(File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"))),"the installed source editor receives one native focus gesture without text/draft/persistence or action changes");
                await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
                Check(gui.Surface.GetTexture().GetImage().SavePng(System.IO.Path.Combine(directory,"editor-"+font+".png"))==Error.Ok,"actual editor working view raster captured at font "+font);
            }
        }
        gui.PresentSpatial(false);gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);gui.Size=new(600,900);await Frame();await Frame();
        var reload=(Button)pane.FindChild("source-reload",true,false);
        await Reveal(reload);Check(new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(reload.GetGlobalRect()),"same source owner remains reachable after narrow desktop reflow");
        gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);xr.PresentWorkspace(true);
        await File.WriteAllTextAsync(Env("M1B_RESULT")+".layout.json",JsonSerializer.Serialize(reports));
        xr.WorkspaceDistance(-100);var near=(QuadMesh)xr.GuiSurface.Mesh;
        Check(Angle(near.Size.X,.6)<=50,"explicit near distance retains the central workspace angular span instead of expanding beyond normal task view");
        await Press("disconnect");await app.ViewsDisposed;
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks,physical=false}));
        Console.WriteLine("STAGE2_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    sealed class HeldContinuation(SynchronizationContext owner) : SynchronizationContext
    {
        readonly TaskCompletionSource arrived=new(TaskCreationOptions.RunContinuationsAsynchronously);
        SendOrPostCallback? callback;object? state;int held;
        public Task Arrived=>arrived.Task;
        public override void Post(SendOrPostCallback next,object? value)
        {
            if(value is Action action && action.Target?.GetType().FullName?.Contains("SourcePanel+<Preview>")==true && Interlocked.CompareExchange(ref held,1,0)==0){callback=next;state=value;arrived.TrySetResult();}
            else owner.Post(next,value);
        }
        public void Release(){var next=callback??throw new InvalidOperationException("No real continuation arrived.");callback=null;owner.Post(next,state);}
    }

}
