using Godot;
using Quod.Client;
using Json=Quod.Client.Json;

// Local presentation of one exact subject. Recipes, authorization, drafts,
// scene resources and execution remain with their existing owners.
public partial class EidolonPanel : VBoxContainer
{
    readonly Label context=new() { Name="representation-subject",Text="Selected subject",AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly Label title=new() { Name="representation-title",ThemeTypeVariation="Title",AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly Label status=new() { Name="representation-status",AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly VBoxContainer choices=new() {Name="representation-choices"};
    readonly VBoxContainer content=new() {Name="representation-content"};
    readonly Label placement=new() {Name="representation-placement",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    Button near=null!,personal=null!,browse=null!;
    readonly Dictionary<string,Button> choiceButtons=[];
    VBoxContainer? secondaryChoices;
    Button? moreChoices;
    readonly Label exact=new() { Name="representation-identity",Visible=false,AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly ScenePanel preview=new() { Name="representation-scene",Visible=false };
    public ScenePanel Preview=>preview;
    readonly SourcePanel source=new() { Name="source-tools",Visible=false };
    readonly WorkbenchPanel workbench=new() {Name="ontology-workbench",Visible=false};
    public OperationsPanel Operations { get; }=new() { Name="operations" };
    public Subject? Current { get; private set; }
    public Eidolon? Selected { get; private set; }
    public bool Available { get; private set; }
    public ScenePanel.Selection? Occurrence { get; private set; }
    public bool NearOccurrence { get; private set; }
    public string StatusText=>status.Text;
    public Eidolon[] Offered { get; private set; }=[];
    public Func<Actor?>? CurrentLocation { get; set; }
    public Func<Term,string?>? SubjectLabel { get; set; }
    public event Action? Changed;
    public event Action? HiddenByUser;
    SignedSession session=null!;Accounts accounts=null!;LocalStore store=null!;
    SignedView? discovery,representation;
    Task retired=Task.CompletedTask;
    long generation,selection;
    string? preferred;
    bool disposed,workbenchSource,previewRead;
    public Task Completion=>Task.WhenAll(retired,discovery?.Completion??Task.CompletedTask,
        representation?.Completion??Task.CompletedTask,Operations.Completion,source.Completion);
    public override void _Ready()
    {
        SizeFlagsVertical=SizeFlags.ExpandFill;
        AddChild(context);AddChild(title);
        AddChild(placement);
        var placementActions=new HFlowContainer();AddChild(placementActions);
        near=SpatialGui.ActionButton("Near this object","form-near-object");placementActions.AddChild(near);near.Pressed+=PlaceNear;
        personal=SpatialGui.ActionButton("Personal workspace","form-personal-workspace");placementActions.AddChild(personal);personal.Pressed+=PlacePersonal;
        near.ToggleMode=personal.ToggleMode=true;
        var close=SpatialGui.ActionButton("Close","hide-subject-form");close.TooltipText="Return to current space; keep this form and its draft.";placementActions.AddChild(close);close.Pressed+=()=>HiddenByUser?.Invoke();
        var scroll=new ScrollContainer {Name="subject-task-scroll",HorizontalScrollMode=ScrollContainer.ScrollMode.Disabled,FollowFocus=true,SizeFlagsVertical=SizeFlags.ExpandFill};
        AddChild(scroll);scroll.AddChild(content);content.SizeFlagsHorizontal=SizeFlags.ExpandFill;
        content.AddChild(status);content.AddChild(Operations);content.AddChild(workbench);content.AddChild(source);
        browse=SpatialGui.ActionButton("Views & actions","representation-browse");browse.ToggleMode=true;content.AddChild(browse);
        browse.Pressed+=()=>choices.Visible=browse.ButtonPressed;
        content.AddChild(choices);
        var actions=new HFlowContainer();content.AddChild(actions);
        var inspect=SpatialGui.ActionButton("Inspect storage source","inspect-subject-storage");actions.AddChild(inspect);
        inspect.Pressed+=()=>{var storage=Current?.Target??Operations.SelectedStorage;if(storage!=null&&!Operations.IsWorking)Open(session,accounts,store,storage.Ontology);};
        var details=SpatialGui.ActionButton("Details");actions.AddChild(details);details.Pressed+=()=>exact.Visible=!exact.Visible;
        content.AddChild(exact);
        Operations.SubjectOpened+=SubjectOpened;Operations.Changed+=()=>{
            if(Selected?.Operation==true&&(!Operations.Available||Operations.Current?.Name!=Selected.Style)) {
                WithdrawRepresentation(KeepVisual);Operations.Hide();status.Text="The selected action is unavailable. Choose a current view or action.";
            }
            RefreshContext();inspect.Disabled=Operations.IsWorking||(Current==null&&Operations.SelectedStorage==null);Changed?.Invoke();};
        Operations.Cancelled+=()=>{Retire();Hide();HiddenByUser?.Invoke();Changed?.Invoke();};
        source.Changed+=()=>{workbench.UpdateAccess();Changed?.Invoke();};
        preview.Selected+=s=>{if(workbench.Visible)workbench.Select(s.Subject);else OpenOccurrence(session,accounts,store,s);};
        workbench.CanEdit=()=>source.CanEdit;
        workbench.SourceStatus=()=>source.IsWorking ? "Source operation in progress…" : source.Status;
        workbench.Prepare+=change=>{workbenchSource=true;source.Show();source.PrepareFact(change);};
        workbench.ShowSource+=()=>{workbenchSource=!workbenchSource;source.Visible=workbenchSource;};
        workbench.OpenSubject+=s=>Open(session,accounts,store,s);
    }
    string Caption(Eidolon e)=>e.Operation ? Operations.Offered.FirstOrDefault(o=>o.Name==e.Style)?.Form.Tree.Label??e.Caption
        : e.Purpose.Name switch {
            "playing"=>e.Style.Replace('_',' ')+" view",
            "edition"=>e.Style.Replace('_',' ')+" view · editing",
            "prolog"=>e.Style=="source" ? "Source" : "Source · "+e.Style.Replace('_',' '),
            "inspection"=>"Inspect · "+e.Style.Replace('_',' '),
            _=>e.Caption };
    public void RefreshContext()
    {
        string? name=Current==null||!Available ? null : Occurrence?.Label??SubjectLabel?.Invoke(Current.Exact)??preview.SubjectLabel(Current.Exact);
        context.Text=Current==null ? "Create in an existing storage" : CurrentLocation?.Invoke()?.Entity.ToString()==Current.Exact.ToString() ? "Inspecting current space"+(string.IsNullOrEmpty(name) ? "" : " · "+name)
            : Current.Exact.Name=="ontology_ref" ? "Ontology · "+Current.Target.Namespace : Current.Exact.Name=="class_ref" ? "Class · "+Current.Local
            : string.IsNullOrEmpty(name) ? Operations.SubjectLabel : "Selected · "+name;
        title.Text=Selected==null ? Operations.Current?.Form.Tree.Label??"Views & actions" : Caption(Selected);
        Operations.FormPanel.TitleVisible=Selected?.Operation!=true&&Operations.Current==null;
        status.Visible=status.Text.Length>0;
        foreach(var e in Offered)if(choiceButtons.TryGetValue(e.Exact.ToString(),out var button)) {
            bool selected=Selected?.Exact.ToString()==e.Exact.ToString();
            bool available=Available&&!Operations.IsWorking&&(!e.Operation || Operations.Available&&Operations.Offered.Any(o=>o.Name==e.Style));
            button.Text=(selected ? "✓ " : "")+Caption(e)+(available ? "" : " · unavailable");
            button.Disabled=!available;button.SetPressedNoSignal(selected);
        }
        RefreshPlacement();
    }
    void SetOccurrence(ScenePanel.Selection? next)
    {
        if(Occurrence==next)return;
        if(Occurrence!=null)Occurrence.Owner.PresentationChanged-=OccurrenceChanged;
        Occurrence=next;NearOccurrence=next!=null;
        if(next!=null)next.Owner.PresentationChanged+=OccurrenceChanged;
    }
    void OccurrenceChanged(){RefreshPlacement();Changed?.Invoke();}
    void RefreshPlacement()
    {
        bool current=Occurrence?.Pose!=null;
        near.Disabled=!current;near.SetPressedNoSignal(NearOccurrence);personal.SetPressedNoSignal(!NearOccurrence);
        near.Visible=Occurrence!=null&&!NearOccurrence;personal.Visible=NearOccurrence;
        placement.Text=NearOccurrence ? current ? "Beside · "+(Occurrence!.Label??SubjectLabel?.Invoke(Occurrence.Subject)??"selected object")
            : "This visual occurrence is unavailable. The form is retained; choose Personal workspace to inspect its current authorization."
            : "Personal workspace";
        placement.Visible=NearOccurrence&&!current;
        context.TooltipText=placement.Text;
        placement.TooltipText=Occurrence==null ? "" : Occurrence.Subject+"\nOccurrence: "+Occurrence.Id;
        content.Visible=!NearOccurrence||current;
    }
    public void PlacePersonal(){if(!NearOccurrence)return;NearOccurrence=false;RefreshPlacement();Changed?.Invoke();}
    public void PlaceNear(){if(Occurrence?.Pose==null||NearOccurrence)return;NearOccurrence=true;RefreshPlacement();Changed?.Invoke();}
    public void OpenOccurrence(SignedSession session,Accounts accounts,LocalStore store,ScenePanel.Selection selected)
    {
        if(Operations.IsWorking||selected.Pose==null)return;
        SetOccurrence(selected);Open(session,accounts,store,selected.Subject);RefreshPlacement();Changed?.Invoke();
    }
    void PresentChoices()
    {
        choiceButtons.Clear();foreach(var child in choices.GetChildren()){choices.RemoveChild(child);child.QueueFree();}
        secondaryChoices=null;moreChoices=null;
        foreach(int group in new[]{0,1,2}) {
            var items=Offered.Where(e=>(e.Operation ? 1 : e.Purpose.Name=="playing" ? 0 : 2)==group).ToArray();if(items.Length==0)continue;
            VBoxContainer container=choices;
            if(group==2) {
                secondaryChoices=new() {Visible=false};
                moreChoices=SpatialGui.ActionButton("More views & editors","representation-more");moreChoices.ToggleMode=true;choices.AddChild(moreChoices);
                moreChoices.Pressed+=()=>{secondaryChoices.Visible=moreChoices.ButtonPressed;Changed?.Invoke();};
                choices.AddChild(secondaryChoices);container=secondaryChoices;
            } else container.AddChild(new Label {Text=group==1 ? "Actions" : "Views",ThemeTypeVariation="Heading"});
            var row=new HFlowContainer();container.AddChild(row);
            foreach(var item in items) {
                var button=SpatialGui.ActionButton(Caption(item));button.ToggleMode=true;button.TooltipText=item.Exact.ToString();
                choiceButtons.Add(item.Exact.ToString(),button);row.AddChild(button);long expected=generation;
                button.Pressed+=()=>{
                    if(!disposed&&expected==generation&&Available&&!Operations.IsWorking&&Offered.Any(e=>e.Exact.ToString()==item.Exact.ToString())&&
                       (!item.Operation||Operations.Available&&Operations.Offered.Any(o=>o.Name==item.Style)))Choose(item,true);
                    RefreshContext();
                };
            }
        }
        RefreshContext();
    }
    void Configure(SignedSession session,Accounts accounts,LocalStore store)
    {
        if(!ReferenceEquals(this.session,session)) {
            Retire();
            if(this.session?.Network!=session.Network || this.accounts?.Human!=accounts.Human || this.session?.Key.PublicText!=session.Key.PublicText){Current=null;preferred=null;}
        }
        this.session=session;this.accounts=accounts;this.store=store;Show();
    }
    public bool Resume(SignedSession session,Accounts accounts,LocalStore store)
    {
        bool same=this.session?.Network==session.Network && this.accounts?.Human==accounts.Human && this.session?.Key.PublicText==session.Key.PublicText;
        if(!same || Current==null)return false;
        Open(session,accounts,store,Current.Exact);return true;
    }
    public void Disconnect()=>Operations.Cancel();
    public void Open(SignedSession session,Accounts accounts,LocalStore store,Term exact)
    {
        if(Operations.IsWorking)return;
        if(Occurrence?.Subject.ToString()!=exact.ToString())SetOccurrence(null);
        Configure(session,accounts,store);var subject=Subject.Decode(exact);
        if(Current?.Exact.ToString()==exact.ToString() && Available)return;
        if(exact.Name=="ontology_ref"){Operations.Suspend();SubjectOpened(subject.Target,exact);}
        else Operations.OpenSubject(session,accounts,subject.Target,exact);
    }
    public void OpenStorage(SignedSession session,Accounts accounts,LocalStore store,Actor? location)
    {SetOccurrence(null);Configure(session,accounts,store);Retire();Current=null;preferred=null;choices.Hide();source.Hide();preview.Hide();Operations.Show();Operations.OpenStorage(session,accounts,location);}
    void SubjectOpened(Actor target,Term exactSubject)
    {
        if(Current?.Exact.ToString()!=exactSubject.ToString())preferred=null;
        Retire(KeepVisual);Current=Subject.Decode(exactSubject);long expected=generation;
        Operations.Hide();
        if(Current.Target.Namespace!=target.Namespace || Current.Target.Anchor!=target.Anchor)throw new FormatException("Subject names another storage identity.");
        exact.Text=exactSubject.ToString();status.Text="Reading this subject's authored representations…";
        choices.Show();PresentChoices();
        discovery=new(session,accounts.Human!,target,"eidolons",SignedSession.ViewGoal(target,Term.Call("entity_eidolons",Current.Local,Term.Variable("View"))));
        discovery.Projection+=message=>{
            if(disposed||expected!=generation)return;
            var next=Eidolon.Decode(Json.S(message,"value"));
            bool same=Offered.Select(x=>x.Exact.ToString()).SequenceEqual(next.Select(x=>x.Exact.ToString()));
            Offered=next;Available=true;
            if(!same)PresentChoices();
            var chosen=next.SingleOrDefault(e=>e.Exact.ToString()==preferred);
            if(preferred==null)chosen=next.FirstOrDefault(e=>e.Purpose.Name=="playing")??next.FirstOrDefault(e=>e.Operation&&e.Style==Operations.Current?.Name)??next.FirstOrDefault(e=>e.Operation)??next.FirstOrDefault();
            if(chosen!=null)Choose(chosen);else{WithdrawRepresentation(KeepVisual);status.Text=next.Length==0 ? "No authored representations are currently offered." : "The selected representation was withdrawn. Choose a current offered representation.";}
            RefreshContext();Changed?.Invoke();
        };
        discovery.Withdrawn+=reason=>{if(expected!=generation)return;Available=false;WithdrawRepresentation(KeepVisual);Operations.Hide();status.Text=reason;RefreshContext();Changed?.Invoke();};
        _=discovery.Start();Changed?.Invoke();
    }
    public void Choose(Eidolon choice,bool reveal=false)
    {
        if(!Available || Current==null || !Offered.Any(e=>e.Exact.ToString()==choice.Exact.ToString()))throw new InvalidOperationException("Choose a current authored representation.");
        if(!choice.Operation&&choice.Purpose.Name!="playing"&&secondaryChoices!=null){secondaryChoices.Show();moreChoices!.SetPressedNoSignal(true);}
        if(Selected?.Exact.ToString()==choice.Exact.ToString()) {
            if(reveal&&choice.Operation)Operations.Choose(choice.Style,true);
            else if(reveal&&preview.Visible)RevealPreview();
            return;
        }
        if(preferred!=choice.Exact.ToString())workbenchSource=false;
        choices.Hide();browse.SetPressedNoSignal(false);
        WithdrawRepresentation(choice.Operation&&KeepVisual);Selected=choice;preferred=choice.Exact.ToString();RefreshContext();
        exact.Text=Current.Exact+"\n"+choice.Exact;
        if(choice.Operation){Operations.Show();Operations.Choose(choice.Style,reveal);status.Text="";Changed?.Invoke();return;}
        Operations.Hide();bool revealPreview=reveal;var viewed=Current;
        string kind=choice.Purpose.Kind=="atom" && choice.Purpose.Name is "playing" or "edition" ? "eidolon_scene" : "eidolon";
        var view=new SignedView(session,accounts.Human!,viewed.Target,kind,SignedSession.ViewGoal(viewed.Target,choice.Read(viewed.Local)));representation=view;previewRead=kind=="eidolon_scene";
        view.Projection+=message=>{
            if(disposed||!ReferenceEquals(representation,view))return;
            if(message["marks"]!=null){preview.ApplyProjection(message,viewed.Target,accounts.Human!,ack=>_ = view.Send(ack));preview.NavigationBlocked=true;preview.Show();if(Selected?.Operation!=true)status.Text="View only. Movement requires an offered action.";if(revealPreview&&Selected?.Exact.ToString()==choice.Exact.ToString()){revealPreview=false;RevealPreview();}}
            else {
                var value=Term.Parse(Json.S(message,"value"));
                if(value.Name=="workbench") {
                    var a=value.Require("workbench",6);
                    var workspace=Term.Call("workspace",Term.Call("prolog_editor",Term.Atom("all")),a[0],a[1],a[2],a[5]);
                    source.Install(session,accounts,store,Current,choice,workspace,Term.Parse(Json.S(message,"dependencies")));
                    workbench.Install(Current.Target,a[3],a[4]);workbench.Show();source.Visible=workbenchSource;preview.Apply(a[3].Require("graph",3)[2]);preview.Show();
                    status.Text="Authored classes, membership and attributes of this exact ontology. Graph layout changes no domain location.";
                } else {source.Install(session,accounts,store,Current,choice,value,Term.Parse(Json.S(message,"dependencies")));source.Show();status.Text="Authorized inspection of this exact subject's storage.";}
            }
            Changed?.Invoke();
        };
        view.Message+=message=>{if(ReferenceEquals(representation,view) && message["frame"]!=null)preview.ApplyFrame(message,ack=>_ = view.Send(ack));};
        view.Withdrawn+=reason=>{
            if(!ReferenceEquals(representation,view))return;
            if(view.Updating){preview.Suspend();workbench.Suspend();source.Suspend();}
            else {preview.Withdraw();workbench.Withdraw();source.Withdraw();}
            preview.Hide();workbench.Hide();status.Text=reason;Changed?.Invoke();
        };
        status.Text="Reading the chosen recipe…";_ = view.Start();Changed?.Invoke();
    }
    void RevealPreview()
    {long expected=generation,chosen=selection;SpatialGui.Reveal(preview,()=>!disposed&&expected==generation&&chosen==selection&&preview.IsVisibleInTree());}
    bool KeepVisual=>previewRead&&ReferenceEquals(Occurrence?.Owner,preview);
    void WithdrawRepresentation(bool retainVisual=false)
    {
        selection++;Selected=null;workbench.Withdraw();workbench.Hide();source.Withdraw();source.Hide();
        if(retainVisual)return;
        previewRead=false;preview.Withdraw();preview.Hide();
        var previous=representation;representation=null;previous?.Dispose();Keep(previous?.Completion??Task.CompletedTask);
    }
    void Keep(Task task)=>retired=retired.IsCompleted ? task : Task.WhenAll(retired,task);
    void Retire(bool retainVisual=false)
    {generation++;Available=false;workbenchSource=false;Offered=[];WithdrawRepresentation(retainVisual);var prior=discovery;discovery=null;prior?.Dispose();Keep(prior?.Completion??Task.CompletedTask);}
    public void DisposeView(){if(disposed)return;disposed=true;SetOccurrence(null);Retire();source.DisposeView();Operations.DisposeView();}
    public void Cancel()=>Operations.Cancel();
    public override void _ExitTree()=>DisposeView();
}
