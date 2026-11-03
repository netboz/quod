using Godot;
using Quod.Client;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task OnboardingJourney()
    {
        string phase=Env("M1B_PHASE");bool fresh=phase=="onboarding-full";
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        Button B(string n)=>(Button)app.FindChild(n,true,false);
        Rect2 Clip(Control c) {var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Reveal(Control c) {var ready=new TaskCompletionSource();SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>ready.TrySetResult());await ready.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();}
        async Task Click(Button b) {
            await Reveal(b);Check(!b.Disabled&&b.IsVisibleInTree()&&Clip(b).Encloses(b.GetGlobalRect()),"current native action is enabled and enclosed: "+b.Name);
            int count=0;void Hit()=>count++;b.Pressed+=Hit;
            try {gui.Move(b.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();}
            finally{b.Pressed-=Hit;}
            Check(count==1&&gui.Captures==0,"one real native pointer press/release reaches the current action");
        }
        async Task Action(string n){
            if(!B(n).IsVisibleInTree() && n=="inspect")await Click(B("client-tools"));
            if(!B(n).IsVisibleInTree() && n=="disconnect")await Click(B("workspace-connection"));
            await Click(B(n));await Until(()=>!Busy);
        }
        async Task Layout(string name,string primary) {
            var title=(Label)app.FindChild("connection-title",true,false);var help=(Label)app.FindChild("connection-help",true,false);var status=(Label)app.FindChild("status",true,false);
            foreach(var mode in new[]{(false,1200,20),(false,560,20),(true,1200,26),(true,1200,48)}) {
                GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
                await Reveal(B(primary));
                await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();
                Check(image.SavePng("/work/"+name+"-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3+".png")==Error.Ok,"current onboarding raster retained");
                var controls=new[]{(Control)title,help,status,B(primary)};
                await File.WriteAllTextAsync("/work/"+name+"-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3+"-geometry.json",JsonSerializer.Serialize(controls.Select(c=>new{name=c.Name.ToString(),rectangle=c.GetGlobalRect().ToString(),clip=Clip(c).ToString(),visible=c.IsVisibleInTree(),enclosed=Clip(c).Encloses(c.GetGlobalRect())})));
                Check(controls.All(c=>c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect())),"current instruction status and primary target enclosed at "+name+" "+mode);
            }
            xr.PresentWorkspace(false);GetTree().Root.Size=new(1200,800);gui.TextSize(20-gui.Appearance.DefaultFontSize);await Frame();await Frame();
        }
        if(phase=="onboarding-layout") {
            await Press("create-key");await Press("connect");await Press("register");await Press("prepare");
            await Layout("prepared","setup");await Press("disconnect");await app.ViewsDisposed;
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks,phase}));
            Console.WriteLine("ONBOARDING_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        if(fresh) {
            Check(B("create-key").ThemeTypeVariation=="PrimaryAction"&&!B("create-operations").IsVisibleInTree(),"no-key UI identifies the local first action without unavailable workspace controls");
            await Layout("no-key","create-key");await Action("create-key");
            Check(!B("create-key").Visible&&!B("import-backup").Visible&&B("connect").ThemeTypeVariation=="PrimaryAction","created key offers connection without duplicate key creation");
        } else Check(State["public_key"]!=null&&B("connect").ThemeTypeVariation=="PrimaryAction","returning or imported key starts offline with explicit Connect");
        await Action("connect");
        if(phase=="onboarding-unallocated") {
            Check(app.ActiveAccounts.Human==null&&!app.ActiveAccounts.CanRegister&&!B("register").Visible,"unallocated imported key cannot replace its missing original account by registration");
            Check(((Label)app.FindChild("connection-title",true,false)).Text=="Account unavailable","imported-key unavailability has a distinct truthful next-state explanation");
        } else {
            if(fresh) {
                Check(app.ActiveAccounts.Human==null&&app.ActiveAccounts.CanRegister&&B("register").ThemeTypeVariation=="PrimaryAction","fresh signed key offers explicit account creation");
                await Action("register");var human=app.ActiveAccounts.Human;
                Check(human!=null&&!B("register").Visible&&B("prepare").ThemeTypeVariation=="PrimaryAction","actual successful signup is labelled created and advances to storage review");
                await Action("prepare");
                Check(app.ActiveAccounts.Prepared!=null&&app.ActiveAccounts.Setup==null&&!app.ActiveStore.Snapshot!.Pending.Any(),"preparation leaves setup uncommitted with no pending action");
                await Layout("prepared","setup");await Action("setup");
            } else Check(app.ActiveAccounts.Setup!=null&&!B("register").Visible&&!B("setup").Visible,"returning account recovers original setup without offering duplicate provisioning");
            await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true);
            var session=app.ActiveSession;var owner=app.ActiveAccounts.Human!;string identity=app.ActiveStore.Snapshot!.Payload,setup=app.ActiveAccounts.Setup!.ToString();
            async Task<string[]> Instructions()=>Json.Binding(await app.ActiveSession.Read(owner,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Select(t=>t.Args[0].ToString()).Order().ToArray();
            var panel=(OperationsPanel)app.FindChild("operations",true,false);
            if(fresh) {
                var original=await Instructions();
                await Action("create-operations");
                var storage=(OptionButton)panel.FindChild("operation-storage",true,false);
                await Choose(storage,Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==owner.Namespace+" @ "+owner.Anchor));await Until(()=>!panel.IsWorking);
                var classes=(OptionButton)panel.FindChild("operation-class",true,false);
                await Choose(classes,Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space"));await Until(()=>panel.Available&&panel.Current?.Name=="create");
                Check(panel.Current!.Subject.ToString()==Term.Call("class_ref",Term.Text(owner.Namespace),Term.Binary(Identity.Decode(owner.Anchor)),Term.Atom("space")).ToString(),"Create uses explicit existing account storage and exact authored class");
                await Click((Button)panel.FormPanel.Input(panel.Current.Form.Submit.ToString())!);await Until(()=>!panel.IsWorking);
                Check(panel.LastOutcome!=null&&Json.Committed(panel.LastOutcome),"one explicit native Create has an actual committed result");
                var created=Result(SpaceResults(panel.LastOutcome!),"space");
                await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
                await Click(panel.FindChild("operation-results",true,false).GetChildren().OfType<Button>().Single(b=>b.TooltipText==created.ToString()));
                await Until(()=>panel.Available&&panel.Current?.Name=="enter");
                await Click((Button)panel.FormPanel.Input(panel.Current!.Form.Submit.ToString())!);await Until(()=>!panel.IsWorking);
                Check(panel.LastOutcome!=null&&Json.Committed(panel.LastOutcome),"one explicit native Move commits Enter through the same form owner");
                await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["current_location"]?.ToString()==Term.Call("placed",created,Term.Parse("transform(0,0,0,0,0,0)")).ToString());
                Check((await Instructions()).Length==original.Length+2,"Create and Enter add exactly two personal instructions");
                await Action("open-gui");await Until(()=>panel.Available&&panel.Current?.Name=="controller_settings");
                var field=panel.FormPanel.Draft.First(p=>panel.FormPanel.Input(p.Key) is LineEdit);var input=(LineEdit)panel.FormPanel.Input(field.Key)!;
                input.Text="0.333";input.EmitSignal(LineEdit.SignalName.TextChanged,input.Text);
                Check(!panel.FormPanel.Validate(),"invalid numeric native draft is retained as invalid before disconnect");
                ulong panelId=panel.GetInstanceId();string location=State["current_location"]!.ToString();var instructions=await Instructions();
                var signed=session.Sign(owner,"true.",1);var unknown=new SignedWork(Identity.Digest(signed.Bytes),session.Network,owner,Json.S(signed.Body,"request"),Json.S(signed.Body,"signature"),"onboarding-unsent-crash");
                app.ActiveStore.Update(s=>s.Pending.Add(unknown));
                typeof(Main).GetMethod("UpdateButtons",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(app,null);
                Check(B("resolve").Visible&&B("resolve").ThemeTypeVariation=="PrimaryAction","persisted original-work fixture makes Check original outcomes the explicit next action");
                // Genuine server TEST-option lifetime: one minute, returned by real Authenticate.
                // This only disposable fixture uses the option; production defaults are unchanged.
                await Until(()=>State["state"]?.ToString()=="sign-in-expired");await app.ViewsDisposed;await session.Expiration;
                Check(SignedSession.Now>=session.Expires&&!B("connect").Disabled&&B("connect").Text=="Sign in again"&&SignedView.LiveSockets==0,"actual authenticated fixture expiry retires views and exposes explicit same-key recovery");
                Check(app.ActiveStore.Snapshot!.Pending.Single().Id==unknown.Id&&gui.Captures==0&&!xr.Running,"expiry retains the exact original unknown work and cancels input without renewal");
                await Layout("expired","connect");await Action("connect");
                await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true);
                var resumed=(OperationsPanel)app.FindChild("operations",true,false);
                Check(resumed.GetInstanceId()==panelId&&resumed.FormPanel.Draft[field.Key]=="0.333"&&!resumed.FormPanel.Validate(),"same owned form retains invalid draft through actual expiry and explicit reconnect");
                Check(app.ActiveAccounts.Human==owner&&app.ActiveAccounts.Setup!.ToString()==setup&&app.ActiveStore.Snapshot!.Payload==identity&&State["current_location"]!.ToString()==location,"explicit recovery retains original key U A S0 and current space");
                Check((await Instructions()).SequenceEqual(instructions)&&app.ActiveStore.Snapshot!.Pending.Single().Id==unknown.Id,"original-work recovery never resubmits the preserved unknown journal fixture");
                using(var imported=new LocalStore("/home/test/imported"))imported.Create(app.ActiveStore.PortablePayload());
                using(var other=Identity.Create())using(var imported=new LocalStore("/home/test/unallocated"))imported.Create(other.Payload());
                await File.WriteAllTextAsync("/work/context.json",JsonSerializer.Serialize(new{identity,setup,location,instructions,unknown=unknown.Id}));
            } else {
                var original=JsonNode.Parse(await File.ReadAllTextAsync("/work/context.json"))!;
                Check(app.ActiveAccounts.Setup!.ToString()==original["setup"]!.ToString()&&State["current_location"]!.ToString()==original["location"]!.ToString(),"new process or imported key recovers the same original setup and committed location");
                Check((await Instructions()).SequenceEqual(original["instructions"]!.AsArray().Select(n=>n!.ToString())),"returning and imported discovery add no personal instructions");
                if(phase=="onboarding-return")Check(app.ActiveStore.Snapshot!.Pending.Single().Id==original["unknown"]!.ToString(),"process reopen retains the exact uncertain original association");
            }
        }
        await Action("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0&&!xr.Running,"disconnect retires sockets and text/controller captures without native XR");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks,phase,fixture_expiry_ms=60000,unknown_fixture="durably signed but never sent; crash-between-persist-and-send seam, no admitted-operation claim"}));
        Console.WriteLine("ONBOARDING_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
