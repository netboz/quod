using Godot;
using Quod.Client;

// The scene's verified immutable templates. Actual occurrences have independent
// nodes; authorization withdrawal hides them without shortening source lifetime.
public sealed class RenderModels(Func<ModelAsset,CancellationToken,Task<byte[]>> fetch) : IDisposable
{
    sealed class Entry(ModelAsset asset)
    {
        public ModelAsset Asset=asset;
        public int Users;
        public bool Active=true;
        public CancellationTokenSource Lifetime=new();
        public Task Ready=Task.CompletedTask;
        public Node3D? Template;
        public StaticGlb? Verified;
    }
    public sealed class Lease : IDisposable
    {
        readonly RenderModels owner;
        readonly Entry entry;
        readonly ModelAsset asset;
        bool disposed;
        private Lease(RenderModels owner,Entry entry,ModelAsset asset) { this.owner=owner;this.entry=entry;this.asset=asset; }
        public async Task<Node3D?> Instantiate()
        {
            await entry.Ready;
            if(disposed || !entry.Active)return null;
            entry.Verified!.Admit(asset);
            var node=(Node3D)entry.Template!.Duplicate();owner.InstancesCreated++;owner.NodesBuilt+=CountNodes(node);return node;
        }
        public void Dispose() { if(disposed)return;disposed=true;owner.Releases++;if(--entry.Users==0)owner.Retire(entry); }
        internal static Lease Create(RenderModels owner,object entry,ModelAsset asset)=>new(owner,(Entry)entry,asset);
    }
    readonly Dictionary<string,Entry> entries=[];
    readonly List<Task> pending=[];
    bool disposed;
    public int Acquisitions { get; private set; }
    public int Releases { get; private set; }
    public int Decodes { get; private set; }
    public int InstancesCreated { get; private set; }
    public int InstancesReleased { get; private set; }
    public int NodesBuilt { get; private set; }
    public int TexturesDecoded { get; private set; }
    public int LiveTemplates=>entries.Count;
    public int LiveLeases=>Acquisitions-Releases;
    public Task Completion=>Task.WhenAll(pending.Select(async task=> {
        try { await task; }catch(OperationCanceledException) { }catch(Exception) { /* Reported by the appearance consumer. Shutdown still releases its owner. */ }
    }));
    static int CountNodes(Node root)=>1+root.GetChildren().Sum(CountNodes);
    public object Metrics=>new { Acquisitions,Releases,Decodes,InstancesCreated,InstancesReleased,NodesBuilt,TexturesDecoded,LiveTemplates,LiveLeases };
    public Lease Acquire(ModelAsset asset)
    {
        ObjectDisposedException.ThrowIf(disposed,this);
        pending.RemoveAll(task=>task.IsCompleted);
        if(!entries.TryGetValue(asset.Digest,out var entry)) {
            entry=new(asset);entries.Add(asset.Digest,entry);entry.Users=1;
            entry.Ready=Load(entry);pending.Add(entry.Ready);
        } else entry.Users++;
        Acquisitions++;return Lease.Create(this,entry,asset);
    }
    async Task Load(Entry entry)
    {
        try {
            byte[] bytes=await fetch(entry.Asset,entry.Lifetime.Token);
            var verified=await Task.Run(()=>StaticGlb.Validate(bytes),entry.Lifetime.Token);verified.Admit(entry.Asset);
            if(!entry.Active)return;
            using var document=new GltfDocument();using var state=new GltfState();
            if(document.AppendFromBuffer(bytes,"",state)!=Error.Ok)throw new FormatException("Verified model could not be decoded by Godot.");
            var template=document.GenerateScene(state) as Node3D??throw new FormatException("Model has no scene root.");
            // Imported names/metadata/scripts never supply Quod targets.
            var textures=new HashSet<ulong>();
            void Clean(Node node) {
                node.SetScript(default);foreach(string key in node.GetMetaList())node.RemoveMeta(key);
                if(node is MeshInstance3D mesh && mesh.Mesh!=null)for(int i=0;i<mesh.Mesh.GetSurfaceCount();i++) {
                    var material=mesh.GetActiveMaterial(i);if(material==null)continue;
                    foreach(var property in material.GetPropertyList()) {
                        string name=property["name"].AsString();var value=material.Get(name);
                        if(value.VariantType==Variant.Type.Object && value.AsGodotObject() is Texture2D texture)textures.Add(texture.GetInstanceId());
                    }
                }
                foreach(var child in node.GetChildren())Clean(child);
            }
            try { Clean(template);entry.Template=template;entry.Verified=verified;Decodes++;NodesBuilt+=CountNodes(template);TexturesDecoded+=textures.Count; }
            catch { template.Free();throw; }
        } catch { if(entry.Active)Retire(entry);throw; }
    }
    public void ReleaseInstance(Node3D node)
    { node.GetParent()?.RemoveChild(node);node.Free();InstancesReleased++; }
    void Retire(Entry entry)
    {
        if(!entry.Active)return;entry.Active=false;entry.Lifetime.Cancel();entry.Template?.Free();entry.Template=null;
        if(entries.GetValueOrDefault(entry.Asset.Digest)==entry)entries.Remove(entry.Asset.Digest);
    }
    public void Dispose()
    { if(disposed)return;disposed=true;foreach(var entry in entries.Values.ToArray())Retire(entry); }
}
