using Godot;
using Quod.Client;
using System.Reflection;
using System.Text.Json.Nodes;
using Json=Quod.Client.Json;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task Onboarding()
    {
        if(Env("M1B_PHASE")=="onboarding-numbers") {await OnboardingNumbers();return;}
        if(Env("M1B_PHASE")=="onboarding-context") {await OnboardingContext();return;}
        if(Env("M1B_PHASE")=="onboarding-source") {await OnboardingSource();return;}
        if(Env("M1B_PHASE") is "onboarding-full" or "onboarding-return" or "onboarding-import" or "onboarding-unallocated" or "onboarding-layout") {await OnboardingJourney();return;}
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        Button Button(string name)=>(Button)app.FindChild(name,true,false);
        async Task Raster(string name) {
            await Frame();await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            using var image=gui.Surface.GetTexture().GetImage();
            string path=System.Environment.GetEnvironmentVariable("GUI_IMAGES")??"/work";
            Check(image.SavePng(path+"/"+name+".png")==Error.Ok,"current startup raster retained");
        }
        string phase=Env("M1B_PHASE");
        if(phase=="onboarding-start") {
            await Raster("no-key");
            Check(!Button("create-key").Disabled&&!Button("import-backup").Disabled&&Button("connect").Disabled,"fresh offline profile permits key creation/import only");
            Check(!Button("open-gui").IsVisibleInTree()&&!Button("create-operations").IsVisibleInTree(),"first-run presentation excludes unavailable account workspace actions");
            Check(Button("create-key").ThemeTypeVariation=="PrimaryAction","fresh first action is recognizable as the primary action");
        } else {
            await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
            await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true);
            if(phase=="onboarding-draft") {
                var pane=(OperationsPanel)app.FindChild("operations",true,false);
                var pair=pane.FormPanel.Draft.First(p=>pane.FormPanel.Input(p.Key) is LineEdit);
                var input=(LineEdit)pane.FormPanel.Input(pair.Key)!;input.Text="0.333";input.EmitSignal(LineEdit.SignalName.TextChanged,input.Text);
                Check(pane.FormPanel.Draft[pair.Key]=="0.333","native unsent form draft changed locally");
                await Press("disconnect");await app.ViewsDisposed;await Press("connect");
                await Until(()=>State["operation_available"]?.GetValue<bool>()==true);
                var restored=(OperationsPanel)app.FindChild("operations",true,false);
                Check(restored.FormPanel.Draft[pair.Key]=="0.333","explicit same-profile reconnect retains the original unsent native form draft");
            } else {
            // Diagnostic-only expiry of this actual client's authenticated session.
            // No system clock, production lifetime, server policy or write is changed.
            typeof(SignedSession).GetProperty("Expires")!.SetValue(app.ActiveSession,SignedSession.Now-1);
            typeof(Main).GetMethod("UpdateButtons",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(app,null);
            await Raster("expired");
            Check(!Button("connect").Disabled,"expired authenticated session exposes explicit same-key recovery");
            }
        }
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=true,checks}));
        Console.WriteLine("ONBOARDING_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task OnboardingNumbers()
    {
        var surface=new SpatialGui();app.AddChild(surface);var panel=new FormPanel();surface.SetContent(panel);
        foreach(string kind in new[]{"slider","rotary_knob"}) {
            var offered=Form.Decode(Term.Parse("component(f,form,[property(label,<<\"Numeric draft\">>)],[component(value,"+kind+",[property(label,<<\"Value\">>),property(range,range(0,10,2))],[]),component(save,button,[property(label,<<\"Save\">>)],[])])"),Term.Parse("[field(value,4)]"),Term.Atom("save"));
            panel.Present(offered);await Frame();await Frame();
            var text=(LineEdit)panel.Input("value")!;var slider=panel.FindChildren("*","HSlider",true,false).OfType<HSlider>().Single();
            Check(slider.Visible&&slider.Value==4&&panel.Validate(),"offered "+kind+" initial value is represented exactly");
            foreach(string invalid in new[]{"0.333","12","3"}) {
                text.Text=invalid;text.EmitSignal(LineEdit.SignalName.TextChanged,invalid);
                Check(panel.Draft["value"]==invalid&&!panel.Validate()&&!slider.Visible,"invalid numeric text remains editable and invalid without an invented slider value: "+kind+" "+invalid);
                var draft=panel.Draft;panel.Present(offered,draft);await Frame();
                text=(LineEdit)panel.Input("value")!;slider=panel.FindChildren("*","HSlider",true,false).OfType<HSlider>().Single();
                Check(ReferenceEquals(panel.Draft,draft)&&text.Text==invalid&&!slider.Visible&&!panel.Validate(),"rebuilding the same invalid "+kind+" draft keeps its text and error");
            }
            text.Text="6";text.EmitSignal(LineEdit.SignalName.TextChanged,text.Text);
            Check(slider.Visible&&slider.Value==6&&panel.Validate(),"corrected native text restores the offered "+kind+" representation");
            slider.Value=8;
            Check(text.Text=="8"&&panel.Draft["value"]=="8"&&panel.Validate(),"native "+kind+" value change still edits the same exact draft");
            panel.Lock(true);slider.Value=10;
            Check(!text.Editable&&!slider.Editable&&panel.Draft["value"]=="8","locked numeric native controls cannot change the draft");
            panel.Lock(false);
        }
        surface.Free();await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
        Console.WriteLine("ONBOARDING_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task OnboardingContext()
    {
        // Native presentation unit: normalized fixture outcomes, no authenticated
        // session or network call and no claim that this fixture committed work.
        using var key=Identity.Create();using var otherKey=Identity.Create();
        using var store=new LocalStore(profile+"-context");store.Create(key.Payload());
        var human=new Actor("fixture:human",Identity.Encode(new byte[32]),"me.");
        SignedSession Consumer(Identity identity,string network,Actor actor) {
            network=Identity.Encode(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(network)));
            var session=new SignedSession(identity,store,new Transport("https://localhost:1",""));
            typeof(SignedSession).GetProperty("Network")!.SetValue(session,network);
            store.Update(s=>s.Accounts[network]=new(actor));return session;
        }
        using var first=Consumer(key,"network-a",human);
        var surface=new SpatialGui();app.AddChild(surface);var pane=new OperationsPanel();surface.SetContent(pane);await Frame();
        var initialize=typeof(OperationsPanel).GetMethod("Initialize",BindingFlags.Instance|BindingFlags.NonPublic)!;
        var show=typeof(OperationsPanel).GetMethod("ShowOutcome",BindingFlags.Instance|BindingFlags.NonPublic)!;
        void Install(SignedSession session)=>initialize.Invoke(pane,new object[]{session,new Accounts(session,store)});
        Install(first);
        var results=(Control)pane.FindChild("operation-results",true,false);
        void Outcome()=>show.Invoke(pane,new object[]{new JsonObject { ["result"]="ok",["bindings"]=new JsonArray(new JsonObject {["Results"]="[result(space,"+(human with {InstanceText="fixture_space."}).Entity+")]"}) }});
        Outcome();Install(first);
        Check(pane.LastOutcome!=null&&results.GetChildCount()==2,"same native consumer retains its explicitly received original result and target");
        foreach(var variant in new[]{"network","key","human"}) {
            store.Update(s=>s.Accounts[first.Network]=new(human));Install(first);
            if(pane.LastOutcome==null)Outcome();
            using var next=Consumer(variant=="key" ? otherKey : key,variant=="network" ? "network-b" : "network-a",variant=="human" ? human with {InstanceText="another."} : human);
            Install(next);
            Check(pane.LastOutcome==null&&results.GetChildCount()==0,"replacement "+variant+" cannot inherit the prior native result or returned-subject action");
        }
        pane.DisposeView();await pane.Completion;surface.Free();
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks,scope="native consumer presentation only; normalized outcome fixture is not a domain commit"}));
        Console.WriteLine("ONBOARDING_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
