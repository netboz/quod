using Godot;
using Quod.Client;
using Json=Quod.Client.Json;

// Local presentation of one exact subject. Recipes, authorization, drafts,
// scene resources and execution remain with their existing owners.
public partial class EidolonPanel : VBoxContainer
{
    readonly Label context=new() { Text="Selected subject",AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly Label status=new() { Name="representation-status",AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly OptionButton choices=FormPanel.Choice("representation-choices");
    readonly Label exact=new() { Name="representation-identity",Visible=false,AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly ScenePanel preview=new() { Name="representation-scene",Visible=false };
    readonly SourcePanel source=new() { Name="source-tools",Visible=false };
    public OperationsPanel Operations { get; }=new() { Name="operations" };
    public Subject? Current { get; private set; }
    public Eidolon? Selected { get; private set; }
    public bool Available { get; private set; }
    public string StatusText=>status.Text;
    public Eidolon[] Offered { get; private set; }=[];
    public event Action? Changed;
    SignedSession session=null!;Accounts accounts=null!;LocalStore store=null!;
    SignedView? discovery,representation;
    Task retired=Task.CompletedTask;
    long generation,selection;
    string? preferred;
    bool disposed;
    public Task Completion=>Task.WhenAll(retired,discovery?.Completion??Task.CompletedTask,
        representation?.Completion??Task.CompletedTask,Operations.Completion,source.Completion);
    public override void _Ready()
    {
        AddChild(context);AddChild(choices);
        var actions=new HFlowContainer();AddChild(actions);
        var inspect=new Button { Name="inspect-subject-storage",Text="Inspect storage source" };actions.AddChild(inspect);
        inspect.Pressed+=()=>{var storage=Current?.Target??Operations.SelectedStorage;if(storage!=null&&!Operations.IsWorking)Open(session,accounts,store,storage.Ontology);};
        var details=new Button { Text="Exact subject / recipe" };actions.AddChild(details);details.Pressed+=()=>exact.Visible=!exact.Visible;
        var close=new Button { Text="Close representation" };actions.AddChild(close);close.Pressed+=Cancel;
        AddChild(exact);AddChild(status);AddChild(Operations);AddChild(preview);AddChild(source);
        Operations.SubjectOpened+=SubjectOpened;Operations.Changed+=()=>{choices.Disabled=Operations.IsWorking||!Available;inspect.Disabled=Operations.IsWorking||(Current==null&&Operations.SelectedStorage==null);Changed?.Invoke();};
        Operations.Cancelled+=()=>{Retire();Hide();Changed?.Invoke();};
        source.Changed+=()=>Changed?.Invoke();preview.Selected+=s=>Open(session,accounts,store,s);
        choices.ItemSelected+=i=>{if(i>0 && i<=Offered.Length && !Operations.IsWorking)Choose(Offered[i-1]);};
    }
    void Configure(SignedSession session,Accounts accounts,LocalStore store)
    {if(!ReferenceEquals(this.session,session))Retire();this.session=session;this.accounts=accounts;this.store=store;Show();}
    public void Open(SignedSession session,Accounts accounts,LocalStore store,Term exact)
    {
        if(Operations.IsWorking)return;
        Configure(session,accounts,store);var subject=Subject.Decode(exact);
        if(Current?.Exact.ToString()==exact.ToString() && Available)return;
        if(exact.Name=="ontology_ref"){Operations.Suspend();SubjectOpened(subject.Target,exact);}
        else Operations.OpenSubject(session,accounts,subject.Target,exact);
    }
    public void OpenStorage(SignedSession session,Accounts accounts,LocalStore store,Actor? location)
    {Configure(session,accounts,store);Retire();Current=null;preferred=null;choices.Hide();source.Hide();preview.Hide();Operations.Show();Operations.OpenStorage(session,accounts,location);}
    void SubjectOpened(Actor target,Term exactSubject)
    {
        if(Current?.Exact.ToString()!=exactSubject.ToString())preferred=null;
        Retire();Current=Subject.Decode(exactSubject);long expected=generation;
        Operations.Hide();
        if(Current.Target.Namespace!=target.Namespace || Current.Target.Anchor!=target.Anchor)throw new FormatException("Subject names another storage identity.");
        context.Text=exactSubject.Name=="ontology_ref" ? "Selected ontology · representations" : "Selected subject · representations";
        exact.Text=exactSubject.ToString();status.Text="Reading this subject's authored representations…";
        choices.Show();choices.Disabled=true;choices.Clear();choices.AddItem("Choose a representation");
        discovery=new(session,accounts.Human!,target,"eidolons",SignedSession.ViewGoal(target,Term.Call("entity_eidolons",Current.Local,Term.Variable("View"))));
        discovery.Projection+=message=>{
            if(disposed||expected!=generation)return;
            var next=Eidolon.Decode(Json.S(message,"value"));
            bool same=Offered.Select(x=>x.Exact.ToString()).SequenceEqual(next.Select(x=>x.Exact.ToString()));
            Offered=next;Available=true;choices.Disabled=Operations.IsWorking;
            if(!same) {choices.Clear();choices.AddItem("Choose a representation");foreach(var item in next)choices.AddItem(item.Caption);}
            var chosen=next.SingleOrDefault(e=>e.Exact.ToString()==preferred);
            if(preferred==null)chosen=next.FirstOrDefault(e=>e.Operation&&e.Style==Operations.Current?.Name)??next.FirstOrDefault(e=>e.Operation)??next.FirstOrDefault();
            if(chosen!=null)Choose(chosen);else{WithdrawRepresentation();status.Text=next.Length==0 ? "No authored representations are currently offered." : "The selected representation was withdrawn. Choose a current offered representation.";}
            Changed?.Invoke();
        };
        discovery.Withdrawn+=reason=>{if(expected!=generation)return;Available=false;choices.Disabled=true;WithdrawRepresentation();Operations.Hide();status.Text=reason;Changed?.Invoke();};
        _=discovery.Start();Changed?.Invoke();
    }
    public void Choose(Eidolon choice)
    {
        if(!Available || Current==null || !Offered.Any(e=>e.Exact.ToString()==choice.Exact.ToString()))throw new InvalidOperationException("Choose a current authored representation.");
        if(Selected?.Exact.ToString()==choice.Exact.ToString())return;
        WithdrawRepresentation();Selected=choice;preferred=choice.Exact.ToString();choices.Select(Array.FindIndex(Offered,e=>e.Exact.ToString()==choice.Exact.ToString())+1);
        exact.Text=Current.Exact+"\n"+choice.Exact;
        if(choice.Operation){Operations.Show();Operations.Choose(choice.Style);status.Text="Offered action. Editing is local until Submit.";Changed?.Invoke();return;}
        Operations.Hide();long expected=generation,selected=selection;
        string kind=choice.Purpose.Kind=="atom" && choice.Purpose.Name is "playing" or "edition" ? "eidolon_scene" : "eidolon";
        representation=new(session,accounts.Human!,Current.Target,kind,SignedSession.ViewGoal(Current.Target,choice.Read(Current.Local)));
        representation.Projection+=message=>{
            if(disposed||expected!=generation||selected!=selection)return;
            if(message["marks"]!=null){preview.ApplyProjection(message,Current.Target,accounts.Human!,ack=>_ = representation.Send(ack));preview.Show();status.Text="Live selected representation. Opening it does not move your agent.";}
            else {
                var value=Term.Parse(Json.S(message,"value"));
                source.Install(session,accounts,store,Current,choice,value);source.Show();status.Text="Authorized inspection of this exact subject's storage.";
            }
            Changed?.Invoke();
        };
        representation.Message+=message=>{if(expected==generation&&selected==selection && message["frame"]!=null)preview.ApplyFrame(message,ack=>_ = representation.Send(ack));};
        representation.Withdrawn+=reason=>{if(expected!=generation||selected!=selection)return;preview.Withdraw();preview.Hide();source.Withdraw();status.Text=reason;Changed?.Invoke();};
        status.Text="Reading the chosen recipe…";_ = representation.Start();Changed?.Invoke();
    }
    void WithdrawRepresentation()
    {
        selection++;Selected=null;preview.Withdraw();preview.Hide();source.Withdraw();source.Hide();
        var previous=representation;representation=null;previous?.Dispose();Keep(previous?.Completion??Task.CompletedTask);
    }
    void Keep(Task task)=>retired=retired.IsCompleted ? task : Task.WhenAll(retired,task);
    void Retire()
    {generation++;Available=false;Offered=[];WithdrawRepresentation();var prior=discovery;discovery=null;prior?.Dispose();Keep(prior?.Completion??Task.CompletedTask);}
    public void DisposeView(){if(disposed)return;disposed=true;Retire();source.DisposeView();Operations.DisposeView();}
    public void Cancel()=>Operations.Cancel();
    public override void _ExitTree()=>DisposeView();
}
