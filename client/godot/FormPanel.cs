using Godot;
using Quod.Client;
using System.Numerics;

// Native controls adapt the existing semantic component tree. Draft strings
// remain exact and local; the offered binder and server validate submissions.
public partial class FormPanel : VBoxContainer
{
    public Form Descriptor { get; private set; } = null!;
    public Dictionary<string, string> Draft { get; private set; } = [];
    public float MinimumFieldHeight {get;init;}=260;
    Label? title;
    bool titleVisible=true;
    // An enclosing presentation may show this same authored title outside its
    // scroll. This changes only the label, never the installed fields/draft.
    public bool TitleVisible {get=>titleVisible;set{titleVisible=value;if(title!=null)title.Visible=value;}}
    public event Action<string>? Invoked;
    public event Action? Edited;
    readonly Dictionary<string, Control> controls = [];
    readonly Dictionary<string, Control[]> interactions = [];
    readonly Dictionary<string, Label> errors = [];
    sealed class AppearanceSurface(PanelContainer panel)
    { public readonly PanelContainer Panel=panel;public Theme? Theme;public string Signature="",Layout=""; }
    readonly Dictionary<string,AppearanceSurface> surfaces=[];
    readonly StyleBoxEmpty transparent=new();
    SpatialGui? gui;
    bool locked;
    public override void _EnterTree()
    { gui=GetViewport().GetParent() as SpatialGui;if(gui!=null)gui.AppearancePreferencesChanged+=RefreshAppearancePreferences;RefreshAppearancePreferences(); }
    public override void _ExitTree()
    { if(gui!=null)gui.AppearancePreferencesChanged-=RefreshAppearancePreferences;gui=null; }
    void RefreshAppearancePreferences() { if(Descriptor!=null)ApplyAppearance(Descriptor.Tree,[]); }
    public void RefreshAppearance(Component tree)
    {
        if(Descriptor.Tree.Semantic.ToString()!=tree.Semantic.ToString())throw new FormatException("Appearance refresh changes the semantic GUI contract.");
        Descriptor=Descriptor with { Tree=tree };ApplyAppearance(tree,[]);
    }
    void ApplyAppearance(Component field,Dictionary<string,Term> inherited)
    {
        if(field.Family!="container")return;
        var declaration=field.Properties.GetValueOrDefault("appearance")??Term.Atom("inherit");
        var tokens=new Dictionary<string,Term>(inherited);
        foreach(var token in Component.AppearanceTokens(declaration))tokens[token.Key]=token.Value;
        var surface=surfaces[field.Role];bool authored=declaration.Name!="inherit";
        string signature=authored ? string.Join(";",tokens.OrderBy(p=>p.Key).Select(p=>p.Key+"="+p.Value))+":"+(gui?.OpaquePanels??true) : "inherit";
        if(surface.Signature!=signature) {
            string layout=authored ? string.Join(";",new[]{"spacing","padding","corner_radius"}.Select(k=>tokens.GetValueOrDefault(k)?.ToString()??"default")) : "inherit";
            if(surface.Signature.Length>0&&surface.Layout!=layout)gui?.AppearanceLayoutChanging();
            if(authored) {
                surface.Theme??=new Theme();SpatialGui.PaintAppearance(surface.Theme,tokens,gui?.OpaquePanels??true);
                surface.Panel.RemoveThemeStyleboxOverride("panel");surface.Panel.Theme=surface.Theme;
            } else {surface.Panel.Theme=null;surface.Panel.AddThemeStyleboxOverride("panel",transparent);}
            surface.Signature=signature;surface.Layout=layout;
        }
        foreach(var child in field.Children)ApplyAppearance(child,tokens);
    }
    public void Present(Form form, Dictionary<string, string>? draft = null)
        => Present(form,draft,false);
    void Present(Form form,Dictionary<string,string>? draft,bool workspace)
    {
        Clear(); Descriptor = form; Draft = draft ?? new(form.Defaults);
        AddChild(Render(form.Tree,true,workspace));
        ApplyAppearance(form.Tree,[]);
        if(draft!=null)Validate();
    }
    public void Present(Component workspace,bool preserveDraft=false)
    {
        var values=workspace.Leaves.Where(c=>c.Input).ToDictionary(c=>c.Role,c=>
            preserveDraft&&Descriptor!=null&&Descriptor.Tree.Leaves.Any(old=>old.Role==c.Role&&old.Kind==c.Kind)&&Draft.TryGetValue(c.Role,out var value) ? value : "");
        Present(new Form(workspace,Term.Atom("none"),values),null,true);
    }
    public void Clear()
    {
        Descriptor=null!;title=null;
        foreach (var node in GetChildren()) { RemoveChild(node); node.QueueFree(); }
        controls.Clear(); interactions.Clear(); errors.Clear();surfaces.Clear();
    }
    public void Lock(bool value)
    {
        locked = value;
        if (Descriptor == null) return;
        foreach (var field in Descriptor.Tree.Leaves) if (controls.TryGetValue(field.Role, out var primary)) {
            bool enabled = !locked && primary.GetMeta("offered_enabled").AsBool() && !field.Flag("readonly");
            foreach (var control in interactions[field.Role]) {
                if (control is LineEdit or TextEdit) SpatialGui.SetEditable(control,enabled);
                else if (control is BaseButton button) button.Disabled = !enabled;
                else if (control is Slider slider) slider.Editable = enabled;
                else if (control is ItemList list) list.MouseFilter = enabled ? MouseFilterEnum.Stop : MouseFilterEnum.Ignore;
                bool copyable = field.Flag("readonly") && control is LineEdit or TextEdit;
                control.FocusMode = enabled || copyable ? FocusModeEnum.All : FocusModeEnum.None;
                control.SetMeta("locked", !enabled);
            }
        }
    }
    public bool Validate()
    {
        bool valid = true;
        foreach (var field in Descriptor.Tree.Leaves.Where(c => c.Input)) {
            try { field.Draft(Draft[field.Role]); Error(field.Role,""); }
            catch (Exception error) { valid = false; Error(field.Role,error.Message); }
        }
        return valid;
    }
    public Control? Input(string role) => controls.GetValueOrDefault(role);
    public void ShowField(string role,bool visible)
    {
        if(errors.TryGetValue(role,out var error))((Control)error.GetParent()).Visible=visible;
    }
    internal static OptionButton Choice(string name="")
    {
        var choice=new OptionButton { ActionMode=BaseButton.ActionModeEnum.Release,FitToLongestItem=false,ClipText=true };
        choice.CustomMinimumSize=new(0,44);
        choice.GetPopup().AboutToPopup+=()=>{
            var viewport=choice.GetViewport();
            choice.GetPopup().MaxSize=viewport.GuiEmbedSubwindows ? (Vector2I)viewport.GetVisibleRect().Size : Vector2I.Zero;
        };
        choice.ThemeChanged+=()=>{
            var popup=choice.GetPopup();int height=(int)Math.Ceiling(popup.GetThemeFont("font").GetHeight(popup.GetThemeFontSize("font_size")));
            int gap=Math.Max(8,44-height);
            if(popup.GetThemeConstant("v_separation")!=gap)popup.AddThemeConstantOverride("v_separation",gap);
        };
        if(name.Length>0)choice.Name=name;
        return choice;
    }
    public void Edit(string role, string value)
    {
        if (Descriptor==null || locked || !Draft.ContainsKey(role)) return;
        var field = Descriptor.Tree.Leaves.Single(c => c.Role == role);
        if (field.Flag("readonly") || !field.Flag("enabled", true) || !controls[role].GetMeta("offered_enabled").AsBool()) return;
        Draft[role] = value;
        try { field.Draft(value); Error(role,""); }
        catch (Exception error) { Error(role,error.Message); }
        Edited?.Invoke();
    }
    Control Render(Component field,bool enabled,bool workspace=false)
    {
        enabled &= field.Flag("enabled", true);
        if (field.Family == "container") {
            Control content;
            if((workspace || field.Kind=="form") && field.Properties.GetValueOrDefault("layout")?.Name is null or "column") {
                var column=new VBoxContainer {SizeFlagsVertical=SizeFlags.ExpandFill};var fields=new VBoxContainer { SizeFlagsHorizontal=SizeFlags.ExpandFill };
                var actions=new HFlowContainer();
                int footer=field.Children.Length;
                while(footer>0 && field.Children[footer-1].Family=="button")footer--;
                for(int i=0;i<field.Children.Length;i++)(i>=footer ? (Godot.Container)actions : fields).AddChild(Render(field.Children[i],enabled));
                column.AddChild(Wrap(new ScrollContainer { CustomMinimumSize=new(0,MinimumFieldHeight),SizeFlagsHorizontal=SizeFlags.ExpandFill,SizeFlagsVertical=SizeFlags.ExpandFill,HorizontalScrollMode=ScrollContainer.ScrollMode.Disabled,FollowFocus=true },fields));
                column.AddChild(actions);content=column;
            } else if (field.Kind == "tabs") {
                var tabs = new TabContainer();
                foreach (var child in field.Children) {
                    var page = Render(child, enabled); page.Name = "page" + tabs.GetTabCount(); tabs.AddChild(page); tabs.SetTabTitle(tabs.GetTabCount() - 1, child.Label);
                }
                content = tabs;
            } else {
                Godot.Container container = field.Kind == "row" || field.Properties.GetValueOrDefault("layout")?.Name == "row"
                    ? new HFlowContainer() : field.Kind == "grid" || field.Properties.GetValueOrDefault("layout")?.Name == "grid"
                    ? new GridContainer { Columns = field.Properties.TryGetValue("columns", out var n) && n.Integer <= int.MaxValue ? (int)n.Integer : 1 }
                    : new VBoxContainer();
                foreach (var child in field.Children) container.AddChild(Render(child, enabled));
                content = field.Kind == "scroll" ? Wrap(new ScrollContainer { CustomMinimumSize = new(0, 220) }, container) : container;
            }
            content.SizeFlagsHorizontal = SizeFlags.ExpandFill;
            var section = new VBoxContainer { SizeFlagsHorizontal=SizeFlags.ExpandFill,SizeFlagsVertical=SizeFlags.ExpandFill };
            var heading=Label(field.Label);heading.ThemeTypeVariation=field.Kind=="form" ? "Title" : "Heading";section.AddChild(heading);
            if(ReferenceEquals(field,Descriptor.Tree)){title=heading;heading.Visible=titleVisible;}
            string help=field.Properties.GetValueOrDefault("help")?.TextValue??"";
            if(help.Length>0)section.AddChild(Label(help));
            section.AddChild(content);
            var surface=new PanelContainer {ThemeTypeVariation="AuthoredPanel",SizeFlagsHorizontal=SizeFlags.ExpandFill,SizeFlagsVertical=SizeFlags.ExpandFill};
            surface.AddThemeStyleboxOverride("panel",transparent);surface.AddChild(section);surfaces[field.Role]=new(surface);return surface;
        }
        var row = new VBoxContainer { SizeFlagsHorizontal = SizeFlags.ExpandFill };
        if (field.Family is "text" or "number" or "choice" or "editor" or "bindings" or "catalogue") row.AddChild(Label(field.Label));
        Control control;
        switch (field.Family) {
            case "editor": case "bindings":
                var editor=new TextEdit { Editable=enabled && field.Family=="editor" && !field.Flag("readonly"),CustomMinimumSize=new(0,field.Family=="editor" ? 260 : 100),WrapMode=TextEdit.LineWrappingMode.None };
                control=editor;break;
            case "catalogue":
                control=Choice();break;
            case "display":
                control = field.Kind == "separator" ? new HSeparator() : field.Kind == "progress"
                    ? new ProgressBar { Value = (double)field.Properties["percent"].Integer, ShowPercentage = true, TooltipText = field.Label }
                    : Label(field.Label);
                break;
            case "text":
                if (field.Kind == "text_area") {
                    var text = new TextEdit { Text = Draft[field.Role], CustomMinimumSize = new(0, 130), Editable = enabled && !field.Flag("readonly"), WrapMode = TextEdit.LineWrappingMode.Boundary };
                    text.TextChanged += () => Edit(field.Role, text.Text); control = text;
                } else {
                    var line = new LineEdit { Text = Draft[field.Role], Editable = enabled && !field.Flag("readonly") };
                    line.TextChanged += value => Edit(field.Role, value); control = line;
                }
                break;
            case "number":
                var number = new LineEdit { Text = Draft[field.Role], Editable = enabled && !field.Flag("readonly") };
                number.TextChanged += value => Edit(field.Role, value); control = number;
                var numeric = new HBoxContainer(); numeric.AddChild(number); number.SizeFlagsHorizontal = SizeFlags.ExpandFill;
                foreach (int direction in new[] { -1, 1 }) {
                    var step = new Button { Text = direction < 0 ? "−" : "+", Disabled = !enabled || field.Flag("readonly") };
                    step.Pressed += () => {
                        if (locked) return;
                        try { var value = field.Draft(Draft[field.Role]).Integer + direction * field.Range.Step;
                            string next = value.ToString(); field.Draft(next); number.Text = next; Edit(field.Role, next); }
                        catch (Exception error) { Error(field.Role,error.Message); }
                    }; numeric.AddChild(step);
                }
                if (field.Properties.TryGetValue("unit", out var unit)) numeric.AddChild(Label(unit.Kind == "binary" ? unit.TextValue : unit.Name));
                row.AddChild(numeric);
                if (field.Kind is "slider" or "rotary_knob") {
                    var (low, high, step) = field.Range;
                    if (BigInteger.Abs(low) > 9007199254740991L || BigInteger.Abs(high) > 9007199254740991L || high - low > 9007199254740991L)
                        throw new FormatException("Unsupported slider precision; exact integers require number_input.");
                    var slider = new HSlider { MinValue = (double)low, MaxValue = (double)high, Step = (double)step, Editable = enabled && !field.Flag("readonly") };
                    void Reflect() {
                        bool valid=BigInteger.TryParse(number.Text,out var value)&&value>=low&&value<=high&&(value-low)%step==0;
                        slider.Visible=valid;
                        if(valid)slider.SetValueNoSignal((double)value);
                    }
                    number.TextChanged+=_=>Reflect();Reflect();
                    slider.ValueChanged += value => { if (locked) return; string next = ((long)value).ToString(); number.Text = next; Edit(field.Role, next); };
                    row.AddChild(slider);
                }
                break;
            case "boolean":
                var check = new CheckButton { Text = field.Label, ButtonPressed = Draft[field.Role] == "true", Disabled = !enabled || field.Flag("readonly") };
                check.Toggled += value => Edit(field.Role, value ? "true" : "false"); control = check; break;
            case "choice":
                if (field.Kind is "selectable_list" or "table" or "radio_group" || field.Flag("multiple")) {
                    var list = new ItemList { SelectMode = field.Flag("multiple") ? ItemList.SelectModeEnum.Multi : ItemList.SelectModeEnum.Single,
                        CustomMinimumSize = new(0, Math.Min(260, field.Options.Length * 38)), AllowReselect = true };
                    var selected = field.Flag("multiple") ? Term.Parse(Draft[field.Role]).Items.Select(t => t.ToString()).ToArray() : [Draft[field.Role]];
                    if (field.Kind == "table") row.AddChild(Label(string.Join(" · ", field.Properties["headings"].Items.Select(t => t.Kind == "binary" ? t.TextValue : t.Name))));
                    for (int i = 0; i < field.Options.Length; i++) {
                        list.AddItem(field.Options[i].Label); list.SetItemTooltip(i, field.Options[i].Value.ToString());
                        if (selected.Contains(field.Options[i].Value.ToString())) list.Select(i, false);
                    }
                    void Selection() { if (locked || !enabled || field.Flag("readonly")) return;
                        var values = list.GetSelectedItems().Select(i => field.Options[i].Value).ToArray();
                        if (values.Length != 0 || field.Flag("multiple")) Edit(field.Role, field.Flag("multiple") ? Term.List(values).ToString() : values[0].ToString()); }
                    list.ItemSelected += _ => Selection(); list.MultiSelected += (_, _) => Selection(); control = list;
                } else {
                    var select = Choice(); select.Disabled = !enabled || field.Flag("readonly");
                    for (int i = 0; i < field.Options.Length; i++) {
                        select.AddItem(field.Options[i].Label); select.SetItemTooltip(i, field.Options[i].Value.ToString());
                        if (field.Options[i].Value.ToString() == Draft[field.Role]) select.Select(i);
                    }
                    select.ItemSelected += index => Edit(field.Role, field.Options[index].Value.ToString()); control = select;
                }
                break;
            case "button":
                var button = SpatialGui.ActionButton(field.Label);button.Disabled=!enabled;
                button.ThemeTypeVariation=field.Role==Descriptor.Submit.ToString() ? "PrimaryAction" : "";
                button.Pressed += () => { if (!locked) Invoked?.Invoke(field.Role); }; control = button; break;
            default: throw new FormatException("Unsupported control.");
        }
        control.Name = "control" + controls.Count; control.SetMeta("role", field.Role); control.SetMeta("offered_enabled", enabled);
        // Reauthorization can revoke focus without replacing the local editor.
        // Keep its selection in the native owner; never restore focus/input.
        if(control is LineEdit lineEditor)lineEditor.DeselectOnFocusLossEnabled=false;
        else if(control is TextEdit textEditor)textEditor.DeselectOnFocusLossEnabled=false;
        control.FocusMode = FocusModeEnum.All; controls[field.Role] = control;
        if(control is BaseButton or LineEdit)control.CustomMinimumSize=new(control.CustomMinimumSize.X,Math.Max(44,control.CustomMinimumSize.Y));
        control.TooltipText = field.Properties.GetValueOrDefault("help")?.TextValue ?? "";
        control.SizeFlagsHorizontal = SizeFlags.ExpandFill;
        if (field.Family != "number") row.AddChild(control);
        var errorLabel = Label("");errorLabel.Visible=false;errorLabel.ThemeTypeVariation="ErrorText";errors[field.Role] = errorLabel; row.AddChild(errorLabel);
        interactions[field.Role] = row.FindChildren("*", "", true, false).OfType<Control>()
            .Where(c => c is LineEdit or TextEdit or BaseButton or Slider or ItemList).ToArray();
        return row;
    }
    static Control Wrap(Godot.Container parent, Control child) { parent.AddChild(child); return parent; }
    void Error(string role,string text) { var label=errors[role];label.Text=text;label.Visible=text.Length>0; }
    static Label Label(string text) => new() { Text = text, AutowrapMode = TextServer.AutowrapMode.WordSmart, SizeFlagsHorizontal = SizeFlags.ExpandFill };
}
