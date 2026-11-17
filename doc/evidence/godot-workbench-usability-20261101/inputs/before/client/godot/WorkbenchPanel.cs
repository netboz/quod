using Godot;
using Quod.Client;

// Native controls for an authored graph; ScenePanel and SourcePanel remain the
// sole scene and draft/proof consumers. This panel owns only local selection.
public partial class WorkbenchPanel : VBoxContainer
{
    readonly Label help=new() { Text="Yellow boxes and links: classes / inheritance. Blue spheres and links: instances / membership. Select a node to inspect its authored relations. Prepare edits here, then inspect the same text draft and use Preview / Save. Create instances through offered class actions. Removal does not cascade.",AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly Label selected=new() {Name="workbench-selection",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly FormPanel form=new() {Name="workbench-form"};
    Term[] nodes=[],facts=[],shown=[];
    string descriptor="",signature="",scope="";
    Term? selectedFact;
    bool available;
    public Term? Selected {get;private set;}
    public int Updates {get;private set;}
    public event Action<Term>? OpenSubject;
    public event Action<Term>? Prepare;
    public event Action? ShowSource;
    public Func<bool> CanEdit {get;set;}=()=>false;
    public override void _Ready()
    {
        AddChild(help);AddChild(selected);AddChild(form);
        form.Invoked+=role=>{
            if(!available||form.Input(role) is BaseButton {Disabled:true})return;
            if(role=="show_source"){ShowSource?.Invoke();return;}
            if(role=="open_subject"){if(available&&Selected!=null)OpenSubject?.Invoke(Selected);return;}
            if(!available||!CanEdit())return;
            try {
                var before=Fact;
                Term change=role switch {
                    "add_class"=>Term.Call("add",ClassFact()),
                    "add_attribute" when Selected!=null=>Term.Call("add",AttributeFact(Subject.Decode(Selected).Local)),
                    "replace_fact" when before?.Name=="isa"=>Term.Call("replace",before,ClassFact()),
                    "replace_fact" when before?.Name=="attribute"=>Term.Call("replace",before,AttributeFact(before.Args[0])),
                    "remove_fact" when before!=null=>Term.Call("remove",before),
                    _=>throw new InvalidOperationException("Select an authored fact first.")};
                Prepare?.Invoke(change);
            }catch(Exception error){selected.Text=error.Message;}
        };
    }
    OptionButton Nodes=>(OptionButton)form.Input("node")!;
    OptionButton Facts=>(OptionButton)form.Input("fact")!;
    OptionButton Parents=>(OptionButton)form.Input("parent")!;
    Term? Fact=>selectedFact;
    string Text(string role)=>((LineEdit)form.Input(role)!).Text;
    void SetText(string role,string value){((LineEdit)form.Input(role)!).Text=value;form.Edit(role,value);}
    Term AtomValue(string role){string value=Text(role);if(value.Length==0)throw new FormatException("Enter the "+role.Replace('_',' ')+" first.");return Term.Atom(value);}
    Term ClassFact(){if(Parents.Selected<=0)throw new FormatException("Choose a current parent class.");return Term.Call("isa",AtomValue("class_name"),Subject.Decode(Term.Parse(Parents.GetItemTooltip(Parents.Selected))).Local);}
    Term AttributeFact(Term local)=>Term.Call("attribute",local,AtomValue("attribute_name"),Term.Text(Text("attribute_value")));
    public void Install(Actor target,Term graph,Term controls)
    {
        graph.Ground();var a=graph.Require("graph",3);
        var next=a[0].Items.Select(n=>{var row=n.Require("node",2);var subject=Subject.Decode(row[1]);
            if(row[0].Name is not ("class" or "instance")||subject.Target.Namespace!=target.Namespace||subject.Target.Anchor!=target.Anchor)throw new FormatException("Unsupported workbench node identity.");
            return subject.Exact;}).ToArray();
        if(next.Select(n=>n.ToString()).Distinct().Count()!=next.Length)throw new FormatException("Duplicate workbench node.");
        var tree=Component.Decode(controls);
        foreach(var (role,kind) in new[]{("node","catalogue_selection"),("fact","catalogue_selection"),("parent","catalogue_selection"),("class_name","text_box"),("attribute_name","text_box"),("attribute_value","text_box"),("add_class","button"),("add_attribute","button"),("replace_fact","button"),("remove_fact","button"),("open_subject","button"),("show_source","button")})
            if(!tree.Leaves.Any(c=>c.Role==role&&c.Kind==kind))throw new FormatException("Missing workbench control: "+role);
        string nextScope=target.Namespace+":"+target.Anchor;bool sameScope=scope==nextScope;
        string? parent=sameScope&&form.Input("parent") is OptionButton {Selected:>0} currentParent ? currentParent.GetItemTooltip(currentParent.Selected) : null;
        bool controlsChanged=!sameScope||descriptor!=controls.ToString();
        if(!sameScope){Selected=null;selectedFact=null;signature="";}
        if(controlsChanged) {
            form.Present(tree,sameScope);descriptor=controls.ToString();scope=nextScope;
            Nodes.ItemSelected+=i=>{if(i>0&&i<=nodes.Length)Select(nodes[i-1]);};
            Facts.ItemSelected+=i=>{
                selectedFact=i>0&&i<=shown.Length ? shown[i-1] : null;var f=selectedFact;if(f==null){UpdateAccess();return;}
                if(f.Name=="isa") {SetText("class_name",f.Args[0].Name);
                    for(int p=1;p<Parents.ItemCount;p++)if(Subject.Decode(Term.Parse(Parents.GetItemTooltip(p))).Local.ToString()==f.Args[1].ToString())Parents.Select(p);}
                if(f.Name=="attribute") {SetText("attribute_name",f.Args[1].Name);
                    SetText("attribute_value",f.Args[2].Kind=="binary" ? f.Args[2].TextValue : "");}
                UpdateAccess();
            };
        }
        available=true;
        bool graphChanged=signature!=graph.ToString();
        if(graphChanged){nodes=next;facts=a[1].Items;signature=graph.ToString();Updates++;}
        if(graphChanged||controlsChanged) {
            Parents.Clear();Parents.AddItem("Choose a parent class");
            foreach(var node in nodes.Where(n=>n.Name=="class_ref")){Parents.AddItem(Subject.Decode(node).Local.ToString());Parents.SetItemTooltip(Parents.ItemCount-1,node.ToString());if(node.ToString()==parent)Parents.Select(Parents.ItemCount-1);}
            Nodes.Clear();Nodes.AddItem("Choose a class or instance");
            foreach(var node in nodes){var local=Subject.Decode(node).Local;Nodes.AddItem((node.Name=="class_ref" ? "Class · " : "Instance · ")+local);Nodes.SetItemTooltip(Nodes.ItemCount-1,node.ToString());}
            if(Selected!=null&&nodes.Any(n=>n.ToString()==Selected.ToString()))Select(Selected);
            else {Selected=null;selectedFact=null;Facts.Clear();Facts.AddItem("Select a current node");selected.Text="Choose a node in the scene or list. Layout is presentation only.";}
        }
        UpdateAccess();
    }
    public void Select(Term exact)
    {
        if(!available||!nodes.Any(n=>n.ToString()==exact.ToString()))return;
        if(Selected?.ToString()!=exact.ToString())selectedFact=null;
        Selected=exact;Nodes.Select(Array.FindIndex(nodes,n=>n.ToString()==exact.ToString())+1);
        var local=Subject.Decode(exact).Local;
        shown=facts.Where(f=>f.Name=="attribute" ? f.Args[0].ToString()==local.ToString() : f.Args.Any(x=>x.ToString()==local.ToString())).ToArray();
        Facts.Clear();Facts.AddItem("Choose a current authored fact");foreach(var f in shown){Facts.AddItem(f.ToString());Facts.SetItemTooltip(Facts.ItemCount-1,f.ToString());}
        selectedFact=shown.SingleOrDefault(f=>f.ToString()==selectedFact?.ToString());
        if(selectedFact!=null)Facts.Select(Array.FindIndex(shown,f=>f.ToString()==selectedFact.ToString())+1);
        selected.Text=(exact.Name=="class_ref" ? "Class · " : "Instance · ")+local+" · "+shown.Length+" authored relations/attributes";
        UpdateAccess();
    }
    public void UpdateAccess()
    {
        form.Lock(!available);
        foreach(var role in new[]{"add_class","add_attribute","replace_fact","remove_fact"})if(form.Input(role) is Button b)b.Disabled|=!CanEdit()||role=="add_attribute"&&Selected==null||role=="replace_fact"&&(Fact==null||Fact.Name=="instance_of")||role=="remove_fact"&&Fact==null;
        if(form.Input("open_subject") is Button open)open.Disabled|=Selected==null;
        foreach(var role in new[]{"class_name","attribute_name","attribute_value"})if(form.Input(role) is LineEdit input)input.Editable&=CanEdit();
    }
    // Selection and compatible field text are local inputs, never current authority.
    public void Withdraw(){available=false;signature="";nodes=[];facts=[];shown=[];selected.Text="This view is unavailable.";UpdateAccess();}
}
