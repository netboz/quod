using Quod.Client;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Numerics;

[assembly: System.Runtime.Versioning.SupportedOSPlatform("linux")]

static class Tests
{
    static int checks;
    static void Check(bool value, string name) { if (!value) throw new Exception(name); checks++; Console.WriteLine("PASS " + name); }
    static void Reject(Action action, string name) { try { action(); } catch (Exception) { Check(true, name); return; } throw new Exception("Did not refuse: " + name); }
    public static int Main(string[] args)
    {
        try {
            if (args[0] == "admission-codecs") { AdmissionCodecChecks.Run(); return 0; }
            if (args[0] == "recovery-errors") { awaitRecovery(args[1]); return 0; }
            if (args[0] == "resource-errors") { ResourceErrorChecks.Run().GetAwaiter().GetResult(); return 0; }
            if (args[0] == "crash") { Crash(args); return 0; }
            string repo = Path.GetFullPath(args[0]);
            var corpus = JsonNode.Parse(File.ReadAllText(Path.Combine(repo, "client/test/fixtures/native-contract/contracts.json")))!;
            using var key = Backup.Import(Json.S(corpus, "bundle"), Json.S(corpus, "passphrase"));
            Check(key.PublicText == Json.S(corpus, "public_key"), "browser backup public identity");
            var future = JsonNode.Parse(Json.S(corpus, "bundle"))!; future["version"] = 2;
            Reject(() => Backup.Import(future.ToJsonString(), Json.S(corpus, "passphrase")), "unknown encrypted-backup version refuses");
            foreach (var row in corpus["requests"]!.AsArray()) {
                var actor = row!["account"]!;
                byte[] bytes = Wire.Encode(Identity.Decode(Json.S(actor, "network")), key.PublicKey, Identity.Decode(Json.S(row, "operation")),
                    new(Json.S(actor, "namespace"), Json.S(actor, "anchor"), Json.S(actor, "instanceText")), 0,
                    Json.U(row, "deadline"), Json.S(row, "goal"));
                Check(Identity.Encode(bytes) == Json.S(row, "bytes"), "browser exact UTF8 uint64 wire");
                Check(Identity.Encode(key.Sign(bytes)) == Json.S(row, "signature"), "browser Ed25519 signature");
            }
            var challenge = corpus["challenge"]!;
            Check(Identity.Encode(key.Sign(Identity.Decode(Json.S(challenge, "bytes")))) == Json.S(challenge, "signature"), "challenge signature");
            Reject(() => Backup.Import(Json.S(corpus, "bundle"), "wrong passphrase"), "wrong backup passphrase");
            var damaged = JsonNode.Parse(Json.S(corpus, "bundle"))!; byte[] ciphertext = Identity.Decode(Json.S(damaged, "ciphertext")); ciphertext[0] ^= 1;
            damaged["ciphertext"] = Identity.Encode(ciphertext); Reject(() => Backup.Import(damaged.ToJsonString(), Json.S(corpus, "passphrase")), "GCM tamper");
            string encrypted = Backup.Export(key, Json.S(corpus, "passphrase")); using var restored = Backup.Import(encrypted, Json.S(corpus, "passphrase"));
            Check(restored.PublicText == key.PublicText, "new encrypted backup restores original identity");
            if (args.Length > 1) File.WriteAllText(args[1], encrypted);
            foreach (var row in corpus["terms"]!.AsArray()) Check(Term.Parse(Json.S(row, "text")).ToString() == Json.S(row, "canonical"), "functional data term canonical bytes");
            foreach (var invalid in corpus["invalidTerms"]!.AsArray()) Reject(() => Term.Parse(invalid!.GetValue<string>()), "malformed functional term");
            int verified = 0;
            foreach (string file in new[] { "production-protocol-fixtures.json", "production-controller-reset-fixtures.json" }) {
                var fixture = JsonNode.Parse(File.ReadAllText(Path.Combine(repo, "doc/evidence/godot-m0-20261027", file)))!;
                foreach (var r in fixture["requests"]!.AsArray()) {
                    byte[] bytes = Identity.Decode(Json.S(r, "request_bytes")); byte mode = Json.S(r, "mode") == "read" ? (byte)0 : (byte)1;
                    // The network occupies the first fixed field after the domain.
                    int domain = System.Text.Encoding.UTF8.GetByteCount("quod.agent.goal.v1\0");
                    byte[] reconstructed = Wire.Encode(bytes.AsSpan(domain, 32).ToArray(), Identity.Decode(Json.S(r, "public_key")),
                        Identity.Decode(Json.S(r, "operation_id")), new(Json.S(r, "namespace"), Json.S(r, "anchor"), Json.S(r, "actor")),
                        mode, Json.U(r, "not_after_ms"), Json.S(r, "goal"));
                    Check(bytes.SequenceEqual(reconstructed) && Identity.Verify(Identity.Decode(Json.S(r, "public_key")), bytes, Identity.Decode(Json.S(r, "signature"))), "production exact request and signature"); verified++;
                }
            }
            Check(verified == 100, "all 100 real production fixtures including Reset");
            Store(key); Forms(); Outcomes(); Scenes(); WorldFrames(); Models(repo);
            Console.WriteLine("CORE_PASS checks=" + checks); return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
    static void awaitRecovery(string path) => RecoveryErrorChecks.Run(path).GetAwaiter().GetResult();
    static void Scenes()
    {
        string anchor = Term.Binary(new byte[32]).ToString();
        string group = $"mark(<<\"source\">>,<<\"group\">>,[],transform(1000,2000,3000,15,35,75),no_surface,unlabelled,depicts(<<\"storage\">>,{anchor},object))";
        string box = "mark(<<\"source/edges\">>,<<\"wire_box\">>,[f(<<\"width\">>,'/'(1,3)),f(<<\"height\">>,1001),f(<<\"depth\">>,'/'(1001,2))],relative(<<\"source\">>,transform(0,0,0,0,0,0)),surface(<<\"#6A90D9\">>,0,700,1000,[]),unlabelled,depicts_nothing)";
        var marks = SceneMark.Decode(Term.Parse("[" + group + "," + box + "]"));
        Check(marks[1].Size[0] == new Length(1,3) && marks[1].Size[1] == new Length(1001,1) && marks[1].Parent == "source", "scene retains odd and submillimetre exact rational lengths and parent");
        Check(Math.Abs(marks[1].Size[0].RenderMetres() - 1f/3000) < 1e-10f, "rational conversion occurs at engine boundary without millimetre rounding");
        Check(marks[0].Subject!.ToString().StartsWith("entity_ref("), "scene keeps exact anchored subject independent of occurrence");
        Check(new Length(100000,1).RenderMetres() == 100, "default wireframe extent is 100 metres");
        var huge = BigInteger.One << 1600;
        Check(Math.Abs(new Length(huge,huge+1).RenderMetres() - .001f) < 1e-9, "wide exact fractions convert without intermediate double overflow");
        Reject(() => SceneMark.Decode(Term.Parse("[" + box + "]")), "orphan relative scene refuses");
        Reject(() => SceneMark.Decode(Term.Parse("[" + group + "," + group + "]")), "duplicate scene occurrence refuses");
        Reject(() => SceneMark.Decode(Term.Parse("[" + group + "," + box.Replace("'/'(1,3)","'/'(2,6)") + "]")), "unreduced scene rational refuses");
        Reject(() => SceneMark.Decode(Term.Parse("[" + group + "," + box.Replace("'/'(1,3)","0.5") + "]")), "floating scene dimensions refuse");
        Reject(() => SceneMark.Decode(Term.Parse("[" + group.Replace(anchor,"<<\"wrong\">>") + "]")), "wrong depicted anchor refuses");
        Reject(() => new Length(BigInteger.One << 2000,1).RenderMetres(), "unrenderable finite extent refuses explicitly");
    }
    static void Models(string repo)
    {
        string digest="bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94";
        byte[] bytes=File.ReadAllBytes(Path.Combine(repo,"priv/explorer/assets/models",digest+".glb"));
        Check(Convert.ToHexStringLower(SHA256.HashData(bytes))==digest,"controller bytes match authored class-selected digest");
        var report=StaticGlb.Validate(bytes);
        var asset=new ModelAsset(digest,"gltf2-static-v1",[-59,-70,-117,59,23,106],[1114152,665696,17551,17344,37,1,4194304]);
        report.Admit(asset);Check(report.Costs.SequenceEqual(asset.Allowed) && report.Bounds.SequenceEqual(asset.Bounds),"portable GLB measurement agrees with existing verified Vive model metadata");
        Reject(()=>report.Admit(asset with { Allowed=[1114151,665696,17551,17344,37,1,4194304] }),"each appearance enforces transfer allowance against reusable verification");
        Reject(()=>report.Admit(asset with { Bounds=[-60,-70,-117,59,23,106] }),"verified model refuses mismatched declared bounds");
        var corrupt=(byte[])bytes.Clone();corrupt[0]=0;Reject(()=>StaticGlb.Validate(corrupt),"invalid GLB is rejected before engine decode");
        uint jsonLength=System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(12,4));
        var document=System.Text.Json.Nodes.JsonNode.Parse(bytes.AsSpan(20,(int)jsonLength))!;document["images"]="malformed";
        byte[] json=System.Text.Encoding.UTF8.GetBytes(document.ToJsonString());int padded=(json.Length+3)/4*4;
        var malformed=new byte[bytes.Length-(int)jsonLength+padded];bytes.AsSpan(0,20).CopyTo(malformed);malformed.AsSpan(20,padded).Fill(32);json.CopyTo(malformed,20);bytes.AsSpan(20+(int)jsonLength).CopyTo(malformed.AsSpan(20+padded));
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(malformed.AsSpan(8,4),(uint)malformed.Length);System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(malformed.AsSpan(12,4),(uint)padded);
        Reject(()=>StaticGlb.Validate(malformed),"malformed optional GLB arrays refuse instead of becoming empty facilities");
    }
    static void WorldFrames()
    {
        var anchor=Term.Binary(new byte[32]); var space=new Actor("world-fixture",Identity.Encode(new byte[32]),"room.");
        var nav=new JsonObject { ["value"]="navigation(18446744073709551616,unplaced,[playing,edition])",["dependencies"]="[]" };
        var location=Navigation.Decode(nav);
        Check(location.Space==null && location.Revision==BigInteger.One<<64,"unplaced navigation preserves a wide committed assignment revision");
        nav["value"]="navigation(1,missing,[playing,edition])";
        Reject(()=>Navigation.Decode(nav),"unknown navigation does not become unplaced");
        string depicts=$"depicts(<<\"source\">>,{anchor},object)";
        var marks=Term.Parse($"[mark(<<\"body\">>,<<\"group\">>,[],body_pose(18446744073709551615,1),no_surface,unlabelled,{depicts}),mark(<<\"copy\">>,<<\"group\">>,[],body_frame_pose(18446744073709551615,1),no_surface,unlabelled,{depicts})]");
        var frame=new JsonObject { ["schema"]=2,["units"]="metres_seconds",["space"]="local",
            ["world"]=$"world_ref(<<\"world-fixture\">>,{anchor},room)",["authority"]=Term.Call("agent_instance_ref",space.Entity.Args).ToString(),
            ["epoch"]="1",["generation"]="1",["incarnation"]=Identity.Encode(new byte[32]),["registration"]=Identity.Encode(new byte[32]),
            ["structure"]="1",["tick"]="7",["origin_seq"]="0",["origin_mm"]=new JsonArray("18446744073709551617","0","0"),
            ["poses"]=new JsonArray(new JsonObject { ["body"]="18446744073709551615",["revision"]="1",
                ["position"]=new JsonArray(1.0,2.0,3.0),["rotation"]=new JsonArray(0.0,0.0,0.0,1.0) }) };
        var projection=new JsonObject { ["view"]="current",["selection"]="active",["marks"]=marks.ToString(),["control"]="none",
            ["view_frame"]=$"view_frame({space.Entity},[],[body_frame(18446744073709551615,1,<<\"source-path\">>,[])])",["frame"]=frame };
        var world=new WorldProjection(projection,space);
        Check(world.Sample!.Origin[0]==BigInteger.Parse("18446744073709551617") && world.Marks[0].Pose.Body==ulong.MaxValue && world.BodyFrames.Count==1,"wide exact origins and body IDs survive independent appearances");
        var control=Term.Parse($"control(agent_instance_ref(<<\"world-fixture\">>,{anchor},room),1,controlled_agent(pilot,1,18446744073709551615,1,motion(free,2000,1600,1000,query_limits(2,0,8,128),[]),viewpoint(eye,pose(vector(0,100,0),rotation(0,0,0)),view_only)))");
        Check(ControlBinding.Decode(control,space,world.Sample)?.Body==ulong.MaxValue,"native control binds the exact signed principal and authoritative body");
        Reject(()=>ControlBinding.Decode(control,space with {InstanceText="another."},world.Sample),"another principal cannot acquire the projected control binding");
        Reject(()=>ControlBinding.Decode(Term.Parse(control.ToString().Replace("view_only","unsupported_tracking")),space,world.Sample),"unqualified tracking mapping cannot silently become a desktop viewpoint");
        var message=new JsonObject { ["view"]="current",["frame"]=frame.DeepClone() };
        Check(!world.Advance(message),"duplicate native cursor does no presentation work");
        message["frame"]!["tick"]="6";Check(!world.Advance(message),"older native tick is ignored");
        message["frame"]!["tick"]="8"; message["view"]="retired";Check(!world.Advance(message),"retired view cannot move current bodies");
        message["view"]="current"; message["frame"]!["registration"]=Identity.Encode(Enumerable.Repeat((byte)1,32).ToArray());
        Check(!world.Advance(message),"retired native registration cannot move current bodies");
        message["frame"]=frame.DeepClone(); message["frame"]!["poses"]![0]!["position"]![0]=99.0;
        Reject(()=>world.Advance(message),"changed pose at the same cursor refuses");
        message["frame"]=frame.DeepClone(); message["frame"]!["tick"]="8"; message["frame"]!["poses"]=new JsonArray();
        Reject(()=>world.Advance(message),"missing required body refuses instead of using static pose");
        message["frame"]=frame.DeepClone();message["frame"]!["tick"]="8";message["frame"]!["origin_mm"]![0]="18446744073709551618";
        Reject(()=>world.Advance(message),"a later tick cannot change the exact origin without advancing its origin sequence");
        message["frame"]=frame.DeepClone(); message["frame"]!["tick"]="8";
        Check(world.Advance(message) && world.Sample.Tick==8,"a real native advance still applies");
        projection["view_frame"]=$"view_frame({space.Entity},[],[])";
        Reject(()=>new WorldProjection(projection,space),"missing decorative source receipt refuses");
        projection["selection"]="unavailable";
        Reject(()=>new WorldProjection(projection,space),"unavailable physical selection never becomes an empty successful scene");
    }
    static void Store(Identity key)
    {
        string root = Path.Combine(Path.GetTempPath(), "quod-m1b-store-tests-" + Guid.NewGuid());
        Directory.CreateDirectory(root, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        string saved;
        using (var store = new LocalStore(root)) {
            store.Create(key.Payload()); string file = Path.Combine(root, "active.json");
            byte[] before = File.ReadAllBytes(file); var modified = File.GetLastWriteTimeUtc(file);
            for (int i = 0; i < 3; i++) { Check(store.Snapshot!.Payload == key.Payload(), "unchanged read exact original key"); store.Update(_ => { }); }
            Check(File.ReadAllBytes(file).SequenceEqual(before) && File.GetLastWriteTimeUtc(file) == modified, "unchanged update does not replace active file");
            Reject(() => new LocalStore(root), "second writer lease");
            string network = Identity.Encode(new byte[32]);
            store.Update(s => s.Accounts[network] = new(new("human:test", network, "me.")));
            saved = store.PortablePayload();
            string backup = Backup.Export(key, "public fixture passphrase", saved);
            string imported = Backup.Decrypt(backup, "public fixture passphrase");
            Check(JsonNode.Parse(imported)!["accounts"]!.AsArray().Count == 1, "portable backup retains exact account references");
        }
        using (var reopened = new LocalStore(root)) Check(reopened.Snapshot!.Accounts.Count == 1, "restart retains account identity");
        using (var faulted = new LocalStore(root)) {
            faulted.DurabilityBoundary = point => { if (point == "after-rename") throw new IOException("Injected directory-durability failure."); };
            Reject(() => faulted.Update(s => s.Endpoint = "https://verified-update.example:14570"), "durability failure remains visible");
            Reject(() => faulted.Update(s => s.Endpoint = "https://must-not-overwrite.example:14570"), "failed durability blocks later overwrites until reopen");
        }
        using (var recovered = new LocalStore(root)) {
            Check(recovered.Snapshot!.Endpoint == "https://verified-update.example:14570", "reopen observes original post-rename result");
            Check(recovered.Snapshot.Payload == key.Payload(), "durability failure preserves original key");
        }
        File.SetUnixFileMode(Path.Combine(root, "active.json"), UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead);
        Reject(() => new LocalStore(root), "insecure active file");
        File.SetUnixFileMode(Path.Combine(root, "active.json"), UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.WriteAllText(Path.Combine(root, "active.json"), "broken"); Reject(() => new LocalStore(root), "corrupt store never replaced");
        File.Delete(Path.Combine(root, "active.json")); File.CreateSymbolicLink(Path.Combine(root, "active.json"), Path.Combine(root, "writer.lock"));
        Reject(() => new LocalStore(root), "symlink refuses");
        // Only this test's newly generated directory is removed.
        Directory.Delete(root, true);
    }
    static void Forms()
    {
        string text = "component(f,form,[property(label,<<\"Generic test\">>)],[component(g,group,[property(label,<<\"Nested\">>)],[component(n,number_input,[property(label,<<\"Exact\">>),property(range,range(18446744073709551615,18446744073709551619,2))],[]),component(c,selection,[property(label,<<\"Choice\">>),property(options,[option(a,<<\"A\">>),option(b,<<\"B\">>)])],[])]),component(save,button,[property(label,<<\"Apply\">>)],[])])";
        var form = Form.Decode(Term.Parse(text), Term.Parse("[field(n,18446744073709551615),field(c,a)]"), Term.Atom("save"));
        var draft = new Dictionary<string, string>(form.Defaults) { ["n"] = "18446744073709551619", ["c"] = "b" };
        Check(form.Fields(draft).ToString() == "[field(n,18446744073709551619),field(c,b)]", "nested generic fields preserve above-uint64 integers");
        draft["n"] = "18446744073709551618"; Reject(() => form.Fields(draft), "offered numeric step");
        draft["n"] = "18446744073709551619"; draft["c"] = "invented"; Reject(() => form.Fields(draft), "choice membership");
        Reject(() => Component.Decode(Term.Parse(text.Replace("number_input", "unknown_widget"))), "unsupported descriptor explicit refusal");
        Reject(() => Component.Decode(Term.Parse(text.Replace("property(label,<<\"Exact\">>)", "property(script,untrusted)"))), "unsupported executable descriptor property");
        Reject(() => Term.Parse("[X]").Ground(), "nonground projection");
        string required = "component(f,form,[property(label,f)],[component(b,checkbox,[property(label,b),property(required,true)],[]),component(c,selectable_list,[property(label,c),property(required,true),property(multiple,true),property(options,[option(a,a)])],[]),component(save,button,[property(label,save)],[])])";
        var initial = Form.Decode(Term.Parse(required), Term.Parse("[field(b,false),field(c,[])]"), Term.Atom("save"));
        Check(initial.Defaults["b"] == "false" && initial.Defaults["c"] == "[]", "required unchecked and empty defaults remain displayable");
        Reject(() => initial.Fields(initial.Defaults), "required defaults still need edits before submission");
        var edited = new Dictionary<string,string>(initial.Defaults) { ["b"] = "true" };
        Reject(() => initial.Fields(edited), "empty required selection still refuses submission");
        edited["c"] = "[a]";
        Check(initial.Fields(edited).ToString() == "[field(b,true),field(c,[a])]", "edited required fields retain exact typed bindings");
        Reject(() => Form.Decode(Term.Parse(required), Term.Parse("[field(b,<<\"false\">>),field(c,[])]"), Term.Atom("save")), "initial boolean type stays strict");
        Reject(() => Form.Decode(Term.Parse(required), Term.Parse("[field(b,false),field(c,[invented])]"), Term.Atom("save")), "initial choice membership stays strict");
    }
    static void Outcomes()
    {
        foreach (string aggregate in new[] { "all_applied", "all_rejected", "mixed" }) {
            var reply = JsonNode.Parse("{\"result\":\"operation_outcome\",\"status\":\"completed\",\"terminal\":true}")!;
            reply["aggregate"] = aggregate;
            Check(Json.Terminal(reply) && Json.Committed(reply) == (aggregate == "all_applied"), "completed vector preserves aggregate " + aggregate);
            reply["result"] = "ok";
            Check(Json.Committed(reply) == (aggregate == "all_applied"), "direct vector preserves aggregate " + aggregate);
        }
        Check(!Json.Committed(JsonNode.Parse("{\"result\":\"operation_outcome\",\"status\":\"completed\",\"terminal\":true}")!), "completed without an aggregate cannot install account refs");
    }
    static void Crash(string[] args)
    {
        using var store = new LocalStore(args[1]);
        if (args[2] == "create") { using var key = Identity.Create(); store.Create(key.Payload()); Console.WriteLine("CREATED"); return; }
        string before = store.Snapshot!.Payload;
        store.DurabilityBoundary = point => { if (point == args[2]) { Console.WriteLine("CRASH_SEAM " + point); Console.Out.Flush(); Console.ReadLine(); throw new Exception("Expected external SIGKILL."); } };
        store.Update(s => s.Endpoint = "https://updated.example:14570");
        Check(store.Snapshot!.Payload == before, "update retains original identity");
    }
}
