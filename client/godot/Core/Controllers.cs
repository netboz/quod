using System.Numerics;
using System.Text.RegularExpressions;

namespace Quod.Client;

public sealed record ModelAsset(string Digest, string Profile, long[] Bounds, long[] Allowed)
{
    public string Identity => Digest + ":" + Profile + ":" + string.Join(',', Bounds) + ":" + string.Join(',', Allowed);
}
public sealed record ControllerComponent(string Name, string Id, string Type, string[] Features);
public sealed record ControllerProfile(string Class, string[] Names, ControllerComponent[] Components, ModelAsset Model);
public sealed record ControllerBinding(string Id, string Role, string Component, string Gesture, string? Modifier, string? Sector, float Threshold, float Fraction);
public sealed record ControllerMapping(BigInteger Revision, string Digest, Dictionary<string,string> Roles, ControllerBinding[] Bindings, ControllerProfile[] Profiles)
{
    // Local sign-in uses only native GUI selection. Signed settings replace it
    // after setup; they alone can assign menu and movement gestures.
    public static ControllerMapping SignIn { get; }=new(0,"local-sign-in",
        new() { ["navigation"]="none",["menu"]="none" },
        [new("select","any","trigger","press_release",null,null,0,0)],
        [new("htc_vive_controller",["htc-vive"],[new("trigger","xr-standard-trigger","trigger",["press"])],
            new("bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94","gltf2-static-v1",
                [-59,-70,-117,59,23,106],[1114152,665696,17551,17344,37,1,4194304]))]);
    static string Atom(Term t) => t.Kind == "atom" ? t.Name : throw new FormatException("Expected controller atom.");
    static T[] Unique<T>(IEnumerable<T> values, Func<T,string> key)
    { var rows=values.ToArray(); if(rows.Select(key).Distinct().Count()!=rows.Length) throw new FormatException("Duplicate controller description."); return rows; }
    static float Permille(Term t) => t.Integer>0 && t.Integer<1000 ? (float)t.Integer/1000 : throw new FormatException("Invalid gesture threshold.");
    public static ControllerMapping? Decode(Term value)
    {
        value.Ground(); var v=value.Require("controller_view",3); var revision=v[0].Integer;
        if(revision<0 || v[1].Kind!="binary" || v[1].Bytes.Length!=32) throw new FormatException("Invalid mapping revision/digest.");
        if(v[2].Kind=="atom" && v[2].Name=="invalid_settings") return null;
        var m=v[2].Require("mapping",4); if(m[0].Integer!=1) throw new FormatException("Unsupported controller contract.");
        var roles=Unique(m[1].Items.Select(row=> {
            var a=row.Require("role",2); string role=Atom(a[0]),hand=Atom(a[1].Require("hand",1)[0]);
            if(role is not ("navigation" or "menu") || hand is not ("left" or "right" or "none")) throw new FormatException("Unsupported controller role.");
            return KeyValuePair.Create(role,hand);
        }),r=>r.Key).ToDictionary();
        if(roles.Count!=2) throw new FormatException("Incomplete controller roles.");
        var bindings=Unique(m[2].Items.Select(row=> {
            var b=row.Require("bind",5); string id=Atom(b[0]),role=Atom(b[1]),component=Atom(b[2]);
            if(role is not ("any" or "navigation" or "menu") || component is not ("trigger" or "grip" or "pad")) throw new FormatException("Unknown binding role/component.");
            string kind=b[3].Name; string? modifier=null,sector=null; float threshold=0,fraction=0;
            string lane=id is "select" or "menu" ? "local" : "control";
            var output=b[4].Require(lane,1)[0];
            if(id=="teleport") { fraction=Permille(output.Require("teleport",1)[0]); }
            else if(Atom(output)!=id) throw new FormatException("Unknown controller output.");
            switch(id) {
                case "select": if(Atom(b[3])!="press_release") throw new FormatException("Invalid selection gesture."); break;
                case "menu": threshold=Permille(b[3].Require("radial",1)[0]); break;
                case "drive": modifier=Atom(b[3].Require("axes_while",1)[0]); if(role=="any") throw new FormatException("Ambiguous continuous travel."); break;
                case "snap": case "teleport":
                    var s=b[3].Require("sector",3); sector=Atom(s[0]); threshold=Permille(s[1]); modifier=Atom(s[2]);
                    if(sector!=(id=="snap" ? "horizontal" : "forward")) throw new FormatException("Unknown direction sector."); break;
                default: throw new FormatException("Unknown controller binding.");
            }
            if((id!="select" && component!="pad") || (modifier!=null && modifier is not ("grip" or "trigger"))) throw new FormatException("Invalid gesture component.");
            return new ControllerBinding(id,role,component,kind,modifier,sector,threshold,fraction);
        }),b=>b.Id);
        if(!bindings.Any(b=>b.Id=="select")) throw new FormatException("No selection binding.");
        var profiles=Unique(m[3].Items.Select(row=> {
            var p=row.Require("profile",2); var c=p[1].Require("controller",4);
            var names=Unique(c[0].Items.Select(n=>n.TextValue),n=>n);
            if(names.Length==0 || names.Any(string.IsNullOrEmpty)) throw new FormatException("Missing input profile.");
            var components=Unique(c[1].Items.Select(row=> {
                var a=row.Require("component",4); string name=Atom(a[0]),type=Atom(a[2]);
                var features=Unique(a[3].Items.Select(Atom),n=>n);
                if(name is not ("trigger" or "grip" or "pad") || type is not ("trigger" or "squeeze" or "touchpad") ||
                    features.Any(f=>f is not ("press" or "value" or "touch" or "axes2"))) throw new FormatException("Unknown controller facility.");
                return new ControllerComponent(name,a[1].TextValue,type,features);
            }),c=>c.Name);
            if(!c[2].Items.Select(Atom).SequenceEqual(new[]{"target_ray","grip"})) throw new FormatException("Unsupported controller poses.");
            var a=c[3].Require("tracked_model",2); if(Atom(a[0])!="grip") throw new FormatException("Unsupported model attachment.");
            var asset=a[1].Require("asset",4); string digest=asset[0].TextValue,format=asset[1].TextValue;
            var bounds=asset[2].Require("bounds",6).Select(t=>checked((long)t.Integer)).ToArray();
            var allowed=asset[3].Require("resources",7).Select(t=>checked((long)t.Integer)).ToArray();
            if(!Regex.IsMatch(digest,"^[a-f0-9]{64}$") || format!="gltf2-static-v1" || allowed.Any(n=>n<=0) || Enumerable.Range(0,3).Any(i=>bounds[i]>=bounds[i+3])) throw new FormatException("Invalid model admission.");
            return new ControllerProfile(Atom(p[0]),names,components,new(digest,format,bounds,allowed));
        }),p=>p.Class);
        if(profiles.Length==0) throw new FormatException("Missing controller descriptions.");
        return new(revision,Identity.Encode(v[1].Bytes),roles,bindings,profiles);
    }
}

// The source is the runtime's live tracker, not a replicated hardware inventory.
public interface IControllerSource
{
    string Hand { get; }
    string[] Profiles { get; }
    string Layout { get; }
    bool Current(ulong frame);
    ComponentSample? Read(string componentId);
}
public sealed record ComponentSample(string Type, string[] Features, bool Pressed, Vector2 Axes)
{
    public bool Neutral => !Pressed && Axes.Length()<0.01f;
}
public interface IControllerConsumer
{
    bool Blocked { get; }
    void Appearance(IControllerSource source, ControllerProfile? profile);
    void Remove(IControllerSource source);
    void Hover(IControllerSource source, string context);
    void Hide(IControllerSource source);
    void Press(IControllerSource source);
    void Release(IControllerSource source);
    void Cancel(IControllerSource source);
    bool OpenMenu(IControllerSource source,Vector2 axes,float threshold);
    void MoveMenu(Vector2 axes,float threshold);
    void CommitMenu();
    void CancelMenu();
    void Drive(IControllerSource source,Vector2 axes);
    void Stop();
    void Snap(IControllerSource source,int direction);
    void Teleport(IControllerSource source,float fraction);
}

// One source-scoped edge/capture owner interprets the signed arbitration v1.
// Cancellation never releases a click, chooses a body or changes permissions.
public sealed class ControllerInput(IControllerConsumer consumer) : IDisposable
{
    sealed class Gesture(ControllerBinding binding,ControllerComponent component,ControllerComponent? modifier)
    {
        public ControllerBinding Binding=binding;
        public ControllerComponent Component=component;
        public ControllerComponent? Modifier=modifier;
        public bool Armed,Down,ModifierDown;
    }
    sealed class Source(IControllerSource source,string id)
    {
        public IControllerSource Input=source;
        public string Id=id,Layout="",Hand="",Reason="";
        public bool Tracked;
        public ulong LastFrame;
        public ControllerProfile? Profile;
        public Gesture[] Gestures=[];
    }
    readonly Dictionary<IControllerSource,Source> sources=[];
    readonly Dictionary<string,Source> choices=[];
    ControllerMapping? mapping;
    Source? pointer,menu,travel;
    bool blocked,disposed;
    int nextId;
    public event Action? Changed;
    public int Count=>sources.Count;
    public string? MenuOwner=>menu?.Id;
    public object Status=>new { available=mapping!=null,revision=mapping?.Revision.ToString(),digest=mapping?.Digest, choices=choices.ToDictionary(p=>p.Key,p=>p.Value.Id), sources=sources.Values.Select(s=>new {
        id=s.Id,hand=s.Input.Hand,profile=s.Profile?.Class??"unsupported",tracked=s.Tracked,bindings=s.Gestures.Select(g=>g.Binding.Id).ToArray(),reason=s.Reason }).ToArray() };
    public (string Id,string Hand,string Profile,bool Tracked,string Reason)[] SourceChoices=>sources.Values.Select(s=>(s.Id,s.Input.Hand,s.Profile?.Class??"unsupported",s.Tracked,s.Reason)).ToArray();
    public string? Choice(string role)=>choices.GetValueOrDefault(role)?.Id;
    public string Description=>(mapping==null ? "Controller settings unavailable; use account operations for an offered repair." : "Saved mapping revision "+mapping.Revision+".")+string.Concat(SourceChoices.Select(s=>"\nSource "+s.Id+": "+s.Hand+", "+s.Profile+", "+(s.Tracked ? "tracked" : "tracking unavailable")+". "+s.Reason));
    public void Add(IControllerSource input)
    { if(disposed || sources.ContainsKey(input))return; sources.Add(input,new(input,(++nextId).ToString())); Resolve(); }
    public void Remove(IControllerSource input)
    {
        if(!sources.Remove(input,out var s))return; Cancel(s); consumer.Hide(input); consumer.Remove(input);
        foreach(var role in choices.Where(p=>p.Value==s).Select(p=>p.Key).ToArray())choices.Remove(role); Resolve();
    }
    public void Install(ControllerMapping? next)
    {
        if(disposed)return;
        if(mapping?.Digest==next?.Digest) { bool revision=mapping?.Revision!=next?.Revision;mapping=next;if(revision)Changed?.Invoke();return; }
        Cancel(); mapping=next; choices.Clear(); Resolve();
    }
    public void SourceChanged() { if(!disposed)Resolve(); }
    Source? Role(string role)
    {
        if(choices.TryGetValue(role,out var selected))return selected;
        if(mapping?.Roles[role]=="none")return null;
        var matches=sources.Values.Where(s=>s.Input.Hand==mapping?.Roles[role]).ToArray(); return matches.Length==1 ? matches[0] : null;
    }
    public bool Choose(string role,string id)
    {
        if(mapping==null || !mapping.Roles.ContainsKey(role))return false;
        if(id=="")choices.Remove(role);
        else {
            var s=sources.Values.SingleOrDefault(s=>s.Id==id); if(s==null || Role(role=="menu" ? "navigation" : "menu")==s)return false;
            choices[role]=s;
        }
        Cancel(); Resolve(); return true;
    }
    void Resolve()
    {
        foreach(var s in sources.Values.Where(s=>s.Hand!=s.Input.Hand))
            foreach(var role in choices.Where(p=>p.Value==s).Select(p=>p.Key).ToArray())choices.Remove(role);
        var navigation=mapping==null ? null : Role("navigation"); var menuSource=mapping==null ? null : Role("menu");
        foreach(var s in sources.Values) {
            bool changed=s.Hand!=s.Input.Hand || s.Layout!=s.Input.Layout;
            s.Hand=s.Input.Hand; s.Layout=s.Input.Layout;
            var profiles=mapping?.Profiles.Where(p=>p.Names.Intersect(s.Input.Profiles).Any()).ToArray()??[];
            s.Profile=profiles.Length==1 ? profiles[0] : null;
            consumer.Appearance(s.Input,s.Profile);
            s.Reason=s.Profile==null ? "No unambiguous supported profile/components." : "";
            var next=new List<Gesture>();
            foreach(var b in mapping?.Bindings??[]) {
                if(s.Profile==null)break;
                var role=b.Role=="any" ? s : b.Role=="navigation" ? navigation : menuSource;
                if(b.Role!="any" && navigation!=null && navigation==menuSource && role==s) { s.Reason="Movement/menu need distinct sources."; continue; }
                if(role!=s) { if(role==null && s.Hand==mapping!.Roles[b.Role])s.Reason="Ambiguous role: choose a source for this session."; continue; }
                var c=s.Profile.Components.SingleOrDefault(c=>c.Name==b.Component); var modifier=s.Profile.Components.SingleOrDefault(c=>c.Name==b.Modifier);
                bool Usable(ControllerComponent? d) => d!=null && s.Input.Read(d.Id) is ComponentSample actual && actual.Type==d.Type && d.Features.All(actual.Features.Contains);
                if(!Usable(c) || (b.Modifier!=null && !Usable(modifier))) { s.Reason="Binding requires unavailable named components."; continue; }
                next.Add(new(b,c!,modifier));
            }
            bool same=!changed && s.Gestures.Length==next.Count && s.Gestures.Zip(next).All(p=>p.First.Binding==p.Second.Binding && p.First.Component.Id==p.Second.Component.Id && p.First.Modifier?.Id==p.Second.Modifier?.Id);
            if(!same) { Cancel(s); s.Gestures=next.ToArray(); }
        }
        Changed?.Invoke();
    }
    void StopTravel()
    {
        if(travel!=null) { consumer.Stop(); travel=null; }
        foreach(var g in sources.Values.SelectMany(s=>s.Gestures).Where(g=>g.Binding.Id is "drive" or "snap" or "teleport"))g.Armed=false;
    }
    void Cancel(Source s)
    {
        if(pointer==s) { consumer.Cancel(s.Input); pointer=null; }
        if(menu==s) { consumer.CancelMenu(); menu=null; }
        if(travel==s) { consumer.Stop(); travel=null; }
        foreach(var g in s.Gestures) { g.Armed=false;g.Down=false; }
    }
    public void Cancel() { foreach(var s in sources.Values)Cancel(s); }
    public void CancelMenu()
    { if(menu==null)return; var s=menu; menu=null;consumer.CancelMenu();foreach(var g in s.Gestures.Where(g=>g.Binding.Id is "menu" or "select"))g.Armed=false; }
    public void MenuSelected()
    { if(menu==null)return;foreach(var g in menu.Gestures.Where(g=>g.Binding.Id=="menu"))g.Armed=false;menu=null; }
    public void ContextChanged()
    { bool next=consumer.Blocked; if(next&&!blocked)StopTravel();blocked=next; }
    public void Frame(ulong frame,bool active)
    {
        if(disposed)return;
        if(sources.Values.Any(s=>s.Hand!=s.Input.Hand || s.Layout!=s.Input.Layout))Resolve();
        ContextChanged();
        var edges=new List<(Source S,Gesture G,ComponentSample C,ComponentSample? M,bool Down,bool Up)>();
        foreach(var s in sources.Values) {
            bool current=active && mapping!=null && frame>s.LastFrame && s.Input.Current(frame);
            s.LastFrame=Math.Max(s.LastFrame,frame);
            if(!current) { Cancel(s);consumer.Hide(s.Input);if(s.Tracked){s.Tracked=false;Changed?.Invoke();}continue; }
            if(!s.Tracked){s.Tracked=true;Changed?.Invoke();}
            if(s.Gestures.Any(g=>g.Binding.Id=="select") && (pointer==null || pointer==s))consumer.Hover(s.Input,menu!=null ? "menu" : consumer.Blocked ? "gui" : "world");
            else consumer.Hide(s.Input);
            foreach(var g in s.Gestures) {
                var c=s.Input.Read(g.Component.Id);var m=g.Modifier==null ? null : s.Input.Read(g.Modifier.Id);
                if(c==null || !float.IsFinite(c.Axes.X+c.Axes.Y) || (g.Modifier!=null && m==null)) { Cancel(s);continue; }
                bool down=c.Pressed&&!g.Down,up=!c.Pressed&&g.Down,wasDown=g.Down;
                g.Down=c.Pressed;
                if(!g.Armed) { g.Armed=c.Neutral && (m?.Neutral??true);g.ModifierDown=m?.Pressed??false;continue; }
                if(wasDown && m!=null && g.ModifierDown!=m.Pressed) { g.Armed=false; if(travel==s){consumer.Stop();travel=null;} }
                g.ModifierDown=m?.Pressed??false;
                if(g.Armed)edges.Add((s,g,c,m,down,up));
            }
        }
        // Capture/menu edges precede every travel contribution, independent of
        // tracker enumeration order. A GUI opening can suppress travel now.
        foreach(var e in edges.Where(e=>e.G.Binding.Id is "select" or "menu")) {
            var (s,g,c,m,down,up)=e;
            if(!g.Armed)continue;
            if(g.Binding.Id=="select") {
                if(down && pointer==null && (menu==null || menu==s)) { StopTravel();pointer=s;consumer.Press(s.Input);ContextChanged(); }
                if(up && pointer==s) { pointer=null;consumer.Release(s.Input);ContextChanged(); }
            } else {
                if(pointer!=null && !(pointer==s && menu==s)) { g.Armed=false;continue; }
                if(down && menu==null && consumer.OpenMenu(s.Input,c.Axes,g.Binding.Threshold)) { StopTravel();menu=s; }
                if(menu==s) { consumer.MoveMenu(c.Axes,g.Binding.Threshold);if(up){menu=null;consumer.CommitMenu();ContextChanged();} }
            }
        }
        foreach(var e in edges.Where(e=>e.G.Binding.Id is not ("select" or "menu"))) {
            var (s,g,c,m,down,up)=e;
            if(!g.Armed)continue;
            if(consumer.Blocked || menu!=null || pointer!=null) { g.Armed=false;if(travel==s){consumer.Stop();travel=null;}continue; }
            if(g.Binding.Id=="drive") {
                var axes=m!.Pressed ? c.Axes : Vector2.Zero;
                if(axes!=Vector2.Zero){travel=s;consumer.Drive(s.Input,axes);}
                else if(travel==s){consumer.Stop();travel=null;}
            } else if(down && !m!.Pressed) {
                if(g.Binding.Sector=="horizontal" && Math.Abs(c.Axes.X)>g.Binding.Threshold && Math.Abs(c.Axes.X)>Math.Abs(c.Axes.Y))consumer.Snap(s.Input,Math.Sign(c.Axes.X));
                else if(g.Binding.Sector=="forward" && c.Axes.Y < -g.Binding.Threshold && Math.Abs(c.Axes.Y)>=Math.Abs(c.Axes.X))consumer.Teleport(s.Input,g.Binding.Fraction);
            }
        }
    }
    public void Dispose() { if(disposed)return;foreach(var s in sources.Keys.ToArray())Remove(s);disposed=true;mapping=null;choices.Clear();Changed=null; }
}
