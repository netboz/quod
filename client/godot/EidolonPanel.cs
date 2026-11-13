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
    readonly VBoxContainer content=new() {Name="representation-content"};
    readonly Label placement=new() {Name="representation-placement",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    Button near=null!,personal=null!,close=null!;
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
    // The thing in the world now drawn in the chosen mode, in its own place.
    ScenePanel.Selection? inPlace;
    void RestoreDisplay(){var thing=inPlace;inPlace=null;thing?.Owner.ShowMode(thing,null);}
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
    // One pie selection in flight: consumed by the discovery that answers it,
    // dropped when another subject opens. Never a mode that outlives it.
    sealed record Request(string Subject,string Choice,bool Execute);
    Request? request;
    // Authored wedge labels for this subject's choices, as the pie showed them.
    readonly Dictionary<string,string> labels=[];
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
        close=SpatialGui.ActionButton("Close","hide-subject-form");close.TooltipText="Close this and return to the current space.";placementActions.AddChild(close);close.Pressed+=Cancel;
        var scroll=new ScrollContainer {Name="subject-task-scroll",HorizontalScrollMode=ScrollContainer.ScrollMode.Disabled,FollowFocus=true,SizeFlagsVertical=SizeFlags.ExpandFill};
        AddChild(scroll);scroll.AddChild(content);content.SizeFlagsHorizontal=SizeFlags.ExpandFill;
        content.AddChild(status);content.AddChild(Operations);content.AddChild(workbench);content.AddChild(source);
        // The pie is the chooser; the panel keeps the opened content, its
        // placement toggle, Close and the exact identity on request.
        var details=SpatialGui.ActionButton("Details");content.AddChild(details);details.Pressed+=()=>{exact.Visible=!exact.Visible;Operations.ShowDetails(exact.Visible);};
        content.AddChild(exact);
        Operations.SubjectOpened+=SubjectOpened;Operations.Changed+=()=>{
            if(Selected?.Operation==true&&(!Operations.Available||Operations.Current?.Name!=Selected.Style)) {
                WithdrawRepresentation(KeepVisual);Operations.Hide();status.Text="The selected action is unavailable. Choose a current view or action.";
            }
            RefreshContext();Changed?.Invoke();};
        // Validated or cancelled, the form is gone: the next opening starts from the subject's default.
        Operations.Closed+=validated=>{if(validated!=null)preferred=null;Retire();exact.Hide();Hide();HiddenByUser?.Invoke();Changed?.Invoke();};
        source.Changed+=()=>{workbench.UpdateAccess();Changed?.Invoke();};
        preview.Selected+=s=>{if(workbench.Visible)workbench.Select(s.Subject);else OpenOccurrence(session,accounts,store,s);};
        workbench.CanEdit=()=>source.CanEdit;
        workbench.SourceStatus=()=>source.IsWorking ? "Source operation in progress…" : source.Status;
        workbench.Prepare+=change=>{workbenchSource=true;source.Show();source.PrepareFact(change);};
        workbench.ShowSource+=()=>{workbenchSource=!workbenchSource;source.Visible=workbenchSource;};
        workbench.OpenSubject+=s=>Open(session,accounts,store,s);
    }
    string Caption(Eidolon e)=>labels.TryGetValue(e.Exact.ToString(),out var authored) ? authored
        : e.Operation ? Operations.Offered.FirstOrDefault(o=>o.Name==e.Style)?.Form.Tree.Label??e.Caption
        : e.Purpose.Name switch {
            "playing"=>e.Style.Replace('_',' ')+" view",
            "edition"=>e.Style.Replace('_',' ')+" view · editing",
            "selected"=>e.Style.Replace('_',' ')+" view · selected",
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
        status.Visible=status.Text.Length>0;close.Disabled=Operations.Pending;
        RefreshPlacement();
    }
    void SetOccurrence(ScenePanel.Selection? next)
    {
        if(Occurrence==next)return;
        // A new pick of the same installed thing keeps the mode it is drawn in.
        if(next==null||Occurrence==null||!ReferenceEquals(Occurrence.Owner,next.Owner)||Occurrence.Id!=next.Id||Occurrence.Identity!=next.Identity)RestoreDisplay();
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
    // A pie leaf is exactly one of this subject's offered choices. An action
    // without input fields runs on selection; one with fields opens its form.
    public void OpenChoice(SignedSession session,Accounts accounts,LocalStore store,MenuTarget chosen,ScenePanel.Selection? occurrence,Actor? source=null)
    {
        if(Operations.IsWorking)return;
        if(occurrence?.Pose!=null&&occurrence.Subject.ToString()==chosen.Subject.ToString())SetOccurrence(occurrence);
        else if(Occurrence?.Subject.ToString()!=chosen.Subject.ToString())SetOccurrence(null);
        var asked=new Request(chosen.Subject.ToString(),chosen.Choice.ToString(),Execute:true);
        var storing=chosen.Subject.Name=="class_ref" ? source : null;
        if(chosen.Label.Length>0)labels[asked.Choice]=chosen.Label;
        if(Current?.Exact.ToString()==asked.Subject&&Available&&ReferenceEquals(this.session,session)&&
            (storing==null||Operations.SelectedStorage?.Ontology.ToString()==storing.Ontology.ToString())) {
            request=null;var offered=Offered.FirstOrDefault(e=>e.Exact.ToString()==asked.Choice);
            if(offered!=null)Choose(offered,reveal:true,execute:true);else status.Text="That choice is no longer offered.";
            RefreshPlacement();Changed?.Invoke();return;
        }
        request=asked;Open(session,accounts,store,chosen.Subject,storing);RefreshPlacement();Changed?.Invoke();
    }
    public void OpenOccurrence(SignedSession session,Accounts accounts,LocalStore store,ScenePanel.Selection selected)
    {
        if(Operations.IsWorking||selected.Pose==null)return;
        SetOccurrence(selected);Open(session,accounts,store,selected.Subject);RefreshPlacement();Changed?.Invoke();
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
        Open(session,accounts,store,Current.Exact,Operations.SelectedStorage);return true;
    }
    public void Disconnect()=>Operations.Cancel();
    public void Open(SignedSession session,Accounts accounts,LocalStore store,Term exact,Actor? storing=null)
    {
        if(Operations.IsWorking)return;
        if(Occurrence?.Subject.ToString()!=exact.ToString())SetOccurrence(null);
        Configure(session,accounts,store);var subject=Subject.Decode(exact);
        if(Current?.Exact.ToString()==exact.ToString() && Available&&
            (storing==null||Operations.SelectedStorage?.Ontology.ToString()==storing.Ontology.ToString()))return;
        if(exact.Name=="ontology_ref"){Operations.Suspend();SubjectOpened(subject.Target,exact);}
        else Operations.OpenSubject(session,accounts,storing??subject.Target,exact);
    }
    public void OpenStorage(SignedSession session,Accounts accounts,LocalStore store,Actor? location)
    {SetOccurrence(null);Configure(session,accounts,store);Retire();Current=null;preferred=null;source.Hide();preview.Hide();Operations.Show();Operations.OpenStorage(session,accounts,location);}
    void SubjectOpened(Actor target,Term exactSubject)
    {
        if(Current?.Exact.ToString()!=exactSubject.ToString())preferred=null;
        if(request!=null&&request.Subject!=exactSubject.ToString())request=null;
        if(request!=null)preferred=request.Choice;
        Retire(KeepVisual);Current=Subject.Decode(exactSubject);long expected=generation;
        Operations.Hide();
        exact.Text=exactSubject.ToString();status.Text="Reading this subject's authored representations…";
        discovery=new(session,accounts.Human!,Current.Target,"eidolons",SignedSession.ViewGoal(Current.Target,Term.Call("entity_eidolons",Current.Local,Term.Variable("View"))));
        discovery.Projection+=message=>{
            if(disposed||expected!=generation)return;
            var next=Eidolon.Decode(Json.S(message,"value"));
            Offered=next;Available=true;
            var chosen=next.SingleOrDefault(e=>e.Exact.ToString()==preferred);
            // A thing shown in the world that offers a selected Eidolon shows it on selection; none is required.
            bool shown=Occurrence!=null&&!ReferenceEquals(Occurrence.Owner,preview);
            if(preferred==null)chosen=(shown ? next.FirstOrDefault(e=>e.Purpose.Name=="selected") : null)??next.FirstOrDefault(e=>e.Purpose.Name=="playing")??next.FirstOrDefault(e=>e.Operation&&e.Style==Operations.Current?.Name)??next.FirstOrDefault(e=>e.Operation)??next.FirstOrDefault();
            var answered=request;request=null;
            bool asked=answered!=null&&chosen?.Exact.ToString()==answered.Choice;
            if(chosen!=null)Choose(chosen,reveal:asked,execute:asked&&answered!.Execute);else{WithdrawRepresentation(KeepVisual);status.Text=next.Length==0 ? "No authored representations are currently offered." : "The selected representation was withdrawn. Choose a current offered representation.";}
            RefreshContext();Changed?.Invoke();
        };
        discovery.Withdrawn+=reason=>{if(expected!=generation)return;Available=false;WithdrawRepresentation(KeepVisual);Operations.Hide();status.Text=reason;RefreshContext();Changed?.Invoke();};
        _=discovery.Start();Changed?.Invoke();
    }
    public void Choose(Eidolon choice,bool reveal=false,bool execute=false)
    {
        if(!Available || Current==null || !Offered.Any(e=>e.Exact.ToString()==choice.Exact.ToString()))throw new InvalidOperationException("Choose a current authored representation.");
        if(Selected?.Exact.ToString()==choice.Exact.ToString()) {
            if(reveal&&choice.Operation)Operations.Choose(choice.Style,true,execute);
            else if(reveal&&preview.Visible)RevealPreview();
            return;
        }
        if(preferred!=choice.Exact.ToString())workbenchSource=false;
        WithdrawRepresentation(choice.Operation&&KeepVisual);Selected=choice;preferred=choice.Exact.ToString();RefreshContext();
        exact.Text=Current.Exact+"\n"+choice.Exact;
        if(choice.Operation){Operations.Show();Operations.Choose(choice.Style,reveal,execute);status.Text="";Changed?.Invoke();return;}
        Operations.Hide();bool revealPreview=reveal;var viewed=Current;
        string kind=choice.Purpose.Kind=="atom" && choice.Purpose.Name is "playing" or "edition" or "selected" ? "eidolon_scene" : "eidolon";
        var view=new SignedView(session,accounts.Human!,viewed.Target,kind,SignedSession.ViewGoal(viewed.Target,choice.Read(viewed.Local)));representation=view;previewRead=kind=="eidolon_scene";
        view.Projection+=message=>{
            if(disposed||!ReferenceEquals(representation,view))return;
            if(message["marks"]!=null){
                // The model of one thing already shown in the world is drawn there, in its place; anything else in the side view.
                var thing=Occurrence;
                if(thing!=null&&!ReferenceEquals(thing.Owner,preview)&&thing.Subject.ToString()==viewed.Exact.ToString()&&thing.Owner.ShowMode(thing,Term.Parse(Json.S(message,"marks")))){inPlace=thing;preview.Withdraw();preview.Hide();status.Text="";}
                else {RestoreDisplay();preview.ApplyProjection(message,viewed.Target,accounts.Human!,ack=>_ = view.Send(ack));preview.NavigationBlocked=true;preview.Show();if(Selected?.Operation!=true)status.Text="View only. Movement requires an offered action.";if(revealPreview&&Selected?.Exact.ToString()==choice.Exact.ToString()){revealPreview=false;RevealPreview();}}
            }
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
        view.Message+=message=>{if(ReferenceEquals(representation,view) && inPlace==null && message["frame"]!=null)preview.ApplyFrame(message,ack=>_ = view.Send(ack));};
        view.Withdrawn+=reason=>{
            if(!ReferenceEquals(representation,view))return;
            if(view.Updating){preview.Suspend();workbench.Suspend();source.Suspend();}
            else {RestoreDisplay();preview.Withdraw();workbench.Withdraw();source.Withdraw();}
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
        RestoreDisplay();previewRead=false;preview.Withdraw();preview.Hide();
        var previous=representation;representation=null;previous?.Dispose();Keep(previous?.Completion??Task.CompletedTask);
    }
    void Keep(Task task)=>retired=retired.IsCompleted ? task : Task.WhenAll(retired,task);
    void Retire(bool retainVisual=false)
    {generation++;Available=false;workbenchSource=false;Offered=[];WithdrawRepresentation(retainVisual);var prior=discovery;discovery=null;prior?.Dispose();Keep(prior?.Completion??Task.CompletedTask);}
    public void DisposeView(){if(disposed)return;disposed=true;SetOccurrence(null);Retire();source.DisposeView();Operations.DisposeView();}
    // Closing gives the form up. A form that was sent stays until its result is known.
    public void Cancel(){if(Operations.Pending)return;preferred=null;Operations.Cancel();}
    public override void _ExitTree()=>DisposeView();
    // The host places the preview elsewhere in its layout; it still lives and
    // dies with this panel.
    public override void _Notification(int what)
    { if(what==NotificationPredelete&&IsInstanceValid(preview))preview.QueueFree(); }
}
