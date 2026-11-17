using Godot;
using Quod.Client;

// Native controls for an authored graph; ScenePanel and SourcePanel remain the
// sole scene and draft/proof consumers. This panel owns only local selection.
public partial class WorkbenchPanel : VBoxContainer
{
    readonly Label help=new() { Text="Select a class or instance to inspect it. Preparation changes only your local draft; Preview and Save are separate steps.",AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly Label selected=new() {Name="workbench-selection",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly Label sourceState=new() {Name="workbench-source-state",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly Label exact=new() {Name="workbench-exact",Visible=false,AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly FormPanel form=new() {Name="workbench-form"};
    Term[] nodes=[],facts=[],shown=[];
    string descriptor="",signature="",scope="",editing="";
    Term? selectedFact;
    bool available;
    public Term? Selected {get;private set;}
    public int Updates {get;private set;}
    public event Action<Term>? OpenSubject;
    public event Action<Term>? Prepare;
    public event Action? ShowSource;
    public Func<bool> CanEdit {get;set;}=()=>false;
    public Func<string> SourceStatus {get;set;}=()=>"";
    public override void _Ready()
    {
        AddChild(help);AddChild(selected);AddChild(sourceState);AddChild(exact);AddChild(form);
        form.Invoked+=role=>{
            if(!available||form.Input(role) is BaseButton {Disabled:true})return;
            if(role=="exact_details"){exact.Visible=!exact.Visible;return;}
            if(role=="show_source"){ShowSource?.Invoke();return;}
            if(role=="open_subject"){if(available&&Selected!=null)OpenSubject?.Invoke(Selected);return;}
            if(role=="cancel_edit"){editing="";UpdateAccess();Reveal("node");return;}
            if(!available||!CanEdit())return;
            if(role is "new_class" or "new_attribute" or "edit_fact") {
                editing=role;UpdateAccess();Reveal(role=="new_class"||Fact?.Name=="isa"&&role=="edit_fact" ? "class_name" : "attribute_name");return;
            }
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
        foreach(var (role,kind) in new[]{("node","catalogue_selection"),("fact","catalogue_selection"),("parent","catalogue_selection"),("class_name","text_box"),("attribute_name","text_box"),("attribute_value","text_box"),("new_class","button"),("new_attribute","button"),("edit_fact","button"),("cancel_edit","button"),("exact_details","button"),("add_class","button"),("add_attribute","button"),("replace_fact","button"),("remove_fact","button"),("open_subject","button"),("show_source","button")})
            if(!tree.Leaves.Any(c=>c.Role==role&&c.Kind==kind))throw new FormatException("Missing workbench control: "+role);
        string nextScope=target.Namespace+":"+target.Anchor;bool sameScope=scope==nextScope;
        string? parent=sameScope&&form.Input("parent") is OptionButton {Selected:>0} currentParent ? currentParent.GetItemTooltip(currentParent.Selected) : null;
        string semantic=tree.Semantic.ToString();bool controlsChanged=!sameScope||descriptor!=semantic;
        if(!sameScope){Selected=null;selectedFact=null;signature="";editing="";exact.Hide();}
        if(controlsChanged) {
            form.Present(tree,sameScope);descriptor=semantic;scope=nextScope;
            Nodes.ItemSelected+=i=>{if(i>0&&i<=nodes.Length)Select(nodes[i-1]);};
            Facts.ItemSelected+=i=>{
                editing="";selectedFact=i>0&&i<=shown.Length ? shown[i-1] : null;var f=selectedFact;if(f==null){UpdateAccess();return;}
                if(f.Name=="isa") {SetText("class_name",f.Args[0].Name);
                    for(int p=1;p<Parents.ItemCount;p++)if(Subject.Decode(Term.Parse(Parents.GetItemTooltip(p))).Local.ToString()==f.Args[1].ToString())Parents.Select(p);}
                if(f.Name=="attribute") {SetText("attribute_name",f.Args[1].Name);
                    SetText("attribute_value",f.Args[2].Kind=="binary" ? f.Args[2].TextValue : "");}
                UpdateAccess();
            };
        }
        if(!controlsChanged)form.RefreshAppearance(tree);
        available=true;
        bool graphChanged=signature!=graph.ToString();
        if(graphChanged){nodes=next;facts=a[1].Items;signature=graph.ToString();Updates++;}
        if(graphChanged||controlsChanged) {
            Parents.Clear();Parents.AddItem("Choose a parent class");
            foreach(var node in nodes.Where(n=>n.Name=="class_ref")){Parents.AddItem(Subject.Decode(node).Local.ToString());Parents.SetItemTooltip(Parents.ItemCount-1,node.ToString());if(node.ToString()==parent)Parents.Select(Parents.ItemCount-1);}
            Nodes.Clear();Nodes.AddItem("Choose a class or instance");
            foreach(var node in nodes){var local=Subject.Decode(node).Local;Nodes.AddItem((node.Name=="class_ref" ? "Class · " : "Instance · ")+local);Nodes.SetItemTooltip(Nodes.ItemCount-1,node.ToString());}
            if(Selected!=null&&nodes.Any(n=>n.ToString()==Selected.ToString()))Select(Selected);
            else {Selected=null;selectedFact=null;editing="";Facts.Clear();Facts.AddItem("Select a current node");selected.Text="Choose a class or instance in the graph or list.";}
        }
        UpdateAccess();
    }
    public void Select(Term exact)
    {
        if(!available||!nodes.Any(n=>n.ToString()==exact.ToString()))return;
        if(Selected?.ToString()!=exact.ToString()){selectedFact=null;editing="";}
        Selected=exact;Nodes.Select(Array.FindIndex(nodes,n=>n.ToString()==exact.ToString())+1);
        var local=Subject.Decode(exact).Local;
        shown=facts.Where(f=>f.Name=="attribute" ? f.Args[0].ToString()==local.ToString() : f.Args.Any(x=>x.ToString()==local.ToString())).ToArray();
        Facts.Clear();Facts.AddItem("Choose a relation or attribute");foreach(var f in shown){Facts.AddItem(Caption(f));Facts.SetItemTooltip(Facts.ItemCount-1,f.ToString());}
        selectedFact=shown.SingleOrDefault(f=>f.ToString()==selectedFact?.ToString());
        if(selectedFact!=null)Facts.Select(Array.FindIndex(shown,f=>f.ToString()==selectedFact.ToString())+1);
        selected.Text=(exact.Name=="class_ref" ? "Class · " : "Instance · ")+local+" · "+shown.Length+" authored relations/attributes";
        UpdateAccess();
    }
    public void UpdateAccess()
    {
        sourceState.Text=available ? SourceStatus() : "This source view is unavailable.";
        form.Lock(!available);
        bool changing=editing.Length>0,classes=editing=="new_class"||editing=="edit_fact"&&Fact?.Name=="isa",attributes=editing=="new_attribute"||editing=="edit_fact"&&Fact?.Name=="attribute";
        foreach(var role in new[]{"node","fact","new_class","new_attribute","edit_fact","remove_fact","open_subject"})form.ShowField(role,!changing);
        foreach(var role in new[]{"class_name","parent"})form.ShowField(role,classes);
        foreach(var role in new[]{"attribute_name","attribute_value"})form.ShowField(role,attributes);
        form.ShowField("add_class",editing=="new_class");form.ShowField("add_attribute",editing=="new_attribute");form.ShowField("replace_fact",editing=="edit_fact");form.ShowField("cancel_edit",changing);
        foreach(var role in new[]{"new_class","new_attribute","edit_fact","add_class","add_attribute","replace_fact","remove_fact"})if(form.Input(role) is Button b)b.Disabled|=!CanEdit()||(role is "new_attribute" or "add_attribute")&&Selected==null||(role is "edit_fact" or "replace_fact")&&(Fact==null||Fact.Name=="instance_of")||role=="remove_fact"&&Fact==null;
        if(form.Input("open_subject") is Button open)open.Disabled|=Selected==null;
        foreach(var role in new[]{"class_name","attribute_name","attribute_value"})if(form.Input(role) is LineEdit input)SpatialGui.SetEditable(input,input.Editable&&CanEdit()&&input.IsVisibleInTree());
        exact.Text=(Selected?.ToString()??"No selected subject")+(Fact==null ? "" : "\n"+Fact)+"\nGraph positions are presentation only. Raw fact removal does not delete other facts, objects or history.";
    }
    static string Caption(Term fact)=>fact.Name switch {
        "isa"=>fact.Args[0]+" inherits from "+fact.Args[1],
        "instance_of"=>fact.Args[1]+" is a member of "+fact.Args[0],
        "attribute"=>fact.Args[1]+" = "+(fact.Args[2].Kind=="binary" ? fact.Args[2].TextValue : fact.Args[2].ToString()),
        _=>fact.ToString() };
    void Reveal(string role){if(form.Input(role) is Control target)SpatialGui.Reveal(target,()=>available&&target.IsVisibleInTree());}
    // Selection and compatible field text are local inputs, never current authority.
    public void Suspend(){available=false;UpdateAccess();}
    public void Withdraw(){available=false;signature="";nodes=[];facts=[];shown=[];selected.Text="This view is unavailable.";UpdateAccess();}
}
