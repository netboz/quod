using System.Buffers.Binary;
using System.Text.Json.Nodes;

namespace Quod.Client;

// The existing gltf2-static-v1 profile at the clean engine boundary. Immutable
// measurements are reusable; each authorized appearance checks its own limits.
public sealed record StaticGlb(long[] Costs,long[] Bounds)
{
    static void Require(bool valid,string reason) { if(!valid)throw new FormatException("GLB profile: "+reason); }
    static JsonArray Rows(JsonNode? value)=>value==null ? [] : value as JsonArray??throw new FormatException("GLB profile: expected array");
    static long Integer(JsonNode? value,long fallback=-1)
    { long n=value==null ? fallback : value.GetValue<long>();Require(n>=0,"invalid integer");return n; }
    static JsonNode Index(JsonArray rows,JsonNode? index)
    { long n=Integer(index);Require(n<rows.Count,"invalid reference");return rows[(int)n]??throw new FormatException("Null GLB row."); }
    static double[] Vector(JsonNode? value,int count,double[] fallback)
    {
        if(value==null)return fallback;
        var result=value.AsArray().Select(v=>v!.GetValue<double>()).ToArray();
        Require(result.Length==count && result.All(double.IsFinite),"invalid transform");return result;
    }
    static void NoExtensions(JsonNode? node)
    {
        if(node is JsonObject obj) { Require(obj["extensions"]==null,"extensions are unsupported");foreach(var pair in obj)NoExtensions(pair.Value); }
        else if(node is JsonArray array)foreach(var child in array)NoExtensions(child);
    }
    static readonly string[] CostNames=["transfer bytes","geometry bytes","vertices","triangles","nodes","materials","image pixels"];
    public void Admit(ModelAsset asset)
    {
        Require(asset.Profile=="gltf2-static-v1" && asset.Allowed.Length==7,"unsupported model profile");
        for(int i=0;i<Costs.Length;i++)Require(Costs[i]<=asset.Allowed[i],$"{CostNames[i]} exceeded: {Costs[i]} > {asset.Allowed[i]}");
        Require(Bounds.SequenceEqual(asset.Bounds),"declared bounds differ from verified geometry");
    }
    public static StaticGlb Validate(byte[] bytes)
    {
        uint U(int at)=>BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(at,4));
        Require(bytes.Length>=20 && U(0)==0x46546c67 && U(4)==2 && U(8)==bytes.Length,"invalid header");
        JsonNode? doc=null;byte[]? bin=null;int at=12;
        while(at<bytes.Length) {
            Require(at<=bytes.Length-8,"truncated chunk");uint length=U(at),type=U(at+4);at+=8;
            Require(length%4==0 && length<=bytes.Length-at,"invalid chunk length");
            if(type==0x4e4f534a && doc==null && bin==null)doc=JsonNode.Parse(bytes.AsSpan(at,(int)length));
            else if(type==0x004e4942 && doc!=null && bin==null)bin=bytes.AsSpan(at,(int)length).ToArray();
            else Require(false,"unexpected chunk");at+=(int)length;
        }
        Require(doc!=null && bin!=null,"JSON and BIN are required");var d=doc!;var data=bin!;
        Require(d["asset"]?["version"]?.ToString()=="2.0" && d["asset"]?["minVersion"]==null,"unsupported version");
        Require(Rows(d["extensionsUsed"]).Count==0 && Rows(d["extensionsRequired"]).Count==0 &&
            d["animations"]==null && d["skins"]==null && d["cameras"]==null,"unsupported scene features");NoExtensions(d);
        var scenes=Rows(d["scenes"]);var buffers=Rows(d["buffers"]);
        Require(scenes.Count==1 && Integer(d["scene"])==0 && buffers.Count==1 && buffers[0]?["uri"]==null,"one local scene/buffer required");
        long bufferLength=Integer(buffers[0]?["byteLength"]);Require(bufferLength<=data.Length && data.Length-bufferLength<4,"invalid buffer length");
        var views=Rows(d["bufferViews"]);var accessors=Rows(d["accessors"]);var nodes=Rows(d["nodes"]);var meshes=Rows(d["meshes"]);
        var materials=Rows(d["materials"]);var images=Rows(d["images"]);var textures=Rows(d["textures"]);var samplers=Rows(d["samplers"]);
        long Offset(JsonNode n)=>Integer(n["byteOffset"],0);
        int Width(JsonNode? n)=>n?.GetValue<int>() switch {5120 or 5121=>1,5122 or 5123=>2,5125 or 5126=>4,_=>0};
        int Components(JsonNode? n)=>n?.ToString() switch {"SCALAR"=>1,"VEC2"=>2,"VEC3"=>3,"VEC4" or "MAT2"=>4,"MAT3"=>9,"MAT4"=>16,_=>0};
        foreach(var part in views)Require(part!=null && Integer(part["buffer"])==0 && part["byteStride"]==null && checked(Offset(part)+Integer(part["byteLength"]))<=bufferLength,"invalid/interleaved buffer view");
        foreach(var row in accessors) {
            var a=row!;Require(a["sparse"]==null && a["bufferView"]!=null,"sparse/unbound accessor");var part=Index(views,a["bufferView"]);
            int width=Width(a["componentType"]),components=Components(a["type"]);long count=Integer(a["count"]),offset=Offset(a);
            Require(width>0 && components>0 && (Offset(part)+offset)%width==0 && checked(offset+checked(width*components*count))<=Integer(part["byteLength"]),"invalid accessor range");
        }
        foreach(var sampler in samplers)foreach(string field in new[]{"wrapS","wrapT"})Require(sampler?[field]==null || sampler[field]!.GetValue<int>() is 33071 or 33648 or 10497,"unsupported sampler");
        foreach(var texture in textures) { _=Index(images,texture?["source"]);if(texture?["sampler"]!=null)_=Index(samplers,texture["sampler"]); }
        foreach(var material in materials)foreach(var slot in new[]{material?["pbrMetallicRoughness"]?["baseColorTexture"],material?["pbrMetallicRoughness"]?["metallicRoughnessTexture"],material?["normalTexture"],material?["occlusionTexture"],material?["emissiveTexture"]})
            if(slot!=null) { _=Index(textures,slot["index"]);Require(Integer(slot["texCoord"],0)==0,"only UV0 supported"); }
        long pixels=0;
        foreach(var image in images) {
            Require(image?["uri"]==null && image?["mimeType"]?.ToString() is "image/png" or "image/jpeg","external/unsupported image");
            var part=Index(views,image!["bufferView"]);pixels=checked(pixels+ImagePixels(data.AsSpan(checked((int)Offset(part)),checked((int)Integer(part["byteLength"]))),image["mimeType"]!.ToString()));
        }
        var usedViews=new HashSet<int>();var statistics=new List<(long Vertices,long Triangles,double[] Low,double[] High)>();
        double[] Low()=>[double.PositiveInfinity,double.PositiveInfinity,double.PositiveInfinity];
        double[] High()=>[double.NegativeInfinity,double.NegativeInfinity,double.NegativeInfinity];
        foreach(var mesh in meshes) {
            var primitives=Rows(mesh?["primitives"]);Require(primitives.Count>0 && mesh?["weights"]==null,"unsupported mesh");
            long vertices=0,triangles=0;var low=Low();var high=High();
            foreach(var primitive in primitives) {
                var p=primitive!;Require(Integer(p["mode"],4)==4 && p["targets"]==null,"only static triangles supported");
                var attrs=p["attributes"] as JsonObject;Require(attrs!=null && attrs["POSITION"]!=null && attrs.All(a=>a.Key is "POSITION" or "NORMAL" or "TANGENT" or "TEXCOORD_0" or "COLOR_0"),"unsupported attributes");
                var position=Index(accessors,attrs!["POSITION"]);long count=Integer(position["count"]);
                Require(count>0 && position["type"]?.ToString()=="VEC3" && Integer(position["componentType"])==5126 && position["normalized"]?.GetValue<bool>()!=true,"positions must be float VEC3");
                var part=Index(views,position["bufferView"]);long offset=Offset(part)+Offset(position);var min=Low();var max=High();
                for(long i=0;i<count;i++)for(int axis=0;axis<3;axis++) {
                    float f=BinaryPrimitives.ReadSingleLittleEndian(data.AsSpan(checked((int)(offset+i*12+axis*4)),4));Require(float.IsFinite(f),"nonfinite vertex");
                    min[axis]=Math.Min(min[axis],f);max[axis]=Math.Max(max[axis],f);
                }
                foreach(var pair in new[]{("min",min),("max",max)}) {
                    var expected=Vector(position[pair.Item1],3,[]);Require(expected.Length==3 && expected.Select((n,i)=>(float)n==pair.Item2[i]).All(b=>b),"position bounds mismatch");
                }
                for(int axis=0;axis<3;axis++){low[axis]=Math.Min(low[axis],min[axis]);high[axis]=Math.Max(high[axis],max[axis]);}
                foreach(var attribute in attrs) {
                    var a=Index(accessors,attribute.Value);Require(Integer(a["count"])==count,"attribute count mismatch");
                    string kind=attribute.Key,type=a["type"]!.ToString();long component=Integer(a["componentType"]);bool normalized=a["normalized"]?.GetValue<bool>()==true;
                    bool shape=kind switch {"POSITION" or "NORMAL"=>type=="VEC3","TANGENT"=>type=="VEC4","TEXCOORD_0"=>type=="VEC2",_=>type is "VEC3" or "VEC4"};
                    bool scalar=component==5126 ? !normalized : normalized && (kind is "NORMAL" or "TANGENT" ? component is 5120 or 5122 : kind!="POSITION" && component is 5121 or 5123);
                    Require(shape && scalar,"invalid vertex attribute");usedViews.Add(checked((int)Integer(a["bufferView"])));
                }
                long indexCount=count;
                if(p["indices"]!=null) {
                    var indices=Index(accessors,p["indices"]);int width=Width(indices["componentType"]);
                    Require(indices["type"]?.ToString()=="SCALAR" && indices["normalized"]?.GetValue<bool>()!=true && Integer(indices["componentType"]) is 5121 or 5123 or 5125,"invalid triangle indices");
                    indexCount=Integer(indices["count"]);var view=Index(views,indices["bufferView"]);long start=Offset(view)+Offset(indices);
                    for(long i=0;i<indexCount;i++) {
                        int index=checked((int)(start+i*width));uint vertex=width==1 ? data[index] : width==2 ? BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(index,2)) : BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(index,4));
                        Require(vertex<count,"triangle index exceeds vertices");
                    }
                    usedViews.Add(checked((int)Integer(indices["bufferView"])));
                }
                Require(indexCount%3==0,"incomplete triangles");if(p["material"]!=null)_=Index(materials,p["material"]);
                vertices=checked(vertices+count);triangles=checked(triangles+indexCount/3);
            }
            statistics.Add((vertices,triangles,low,high));
        }
        var seen=new HashSet<int>();var usedMeshes=new HashSet<int>();var minimum=Low();var maximum=High();long vertexTotal=0,triangleTotal=0;
        double[] identity=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1];
        void Visit(JsonNode? index,double[] parent) {
            int id=checked((int)Integer(index));var node=Index(nodes,index);Require(seen.Add(id),"cyclic/reused node");
            Require(node["camera"]==null && node["skin"]==null && node["weights"]==null,"unsupported node");
            var matrix=Vector(node["matrix"],16,[]);var translation=Vector(node["translation"],3,[0,0,0]);var rotation=Vector(node["rotation"],4,[0,0,0,1]);var scale=Vector(node["scale"],3,[1,1,1]);
            Require(Math.Abs(rotation.Sum(n=>n*n)-1)<0.001,"invalid quaternion");
            if(matrix.Length!=0)Require(node["translation"]==null && node["rotation"]==null && node["scale"]==null && matrix[3]==0 && matrix[7]==0 && matrix[11]==0 && matrix[15]==1,"invalid affine transform");
            else {
                var x=rotation[0];var y=rotation[1];var z=rotation[2];var w=rotation[3];
                matrix=[(1-2*(y*y+z*z))*scale[0],2*(x*y+z*w)*scale[0],2*(x*z-y*w)*scale[0],0,
                    2*(x*y-z*w)*scale[1],(1-2*(x*x+z*z))*scale[1],2*(y*z+x*w)*scale[1],0,
                    2*(x*z+y*w)*scale[2],2*(y*z-x*w)*scale[2],(1-2*(x*x+y*y))*scale[2],0,translation[0],translation[1],translation[2],1];
            }
            var transform=new double[16];for(int c=0;c<4;c++)for(int row=0;row<4;row++)for(int k=0;k<4;k++)transform[c*4+row]+=parent[k*4+row]*matrix[c*4+k];
            if(node["mesh"]!=null) {
                int mesh=checked((int)Integer(node["mesh"]));Require(mesh<statistics.Count,"invalid mesh reference");usedMeshes.Add(mesh);var stat=statistics[mesh];
                vertexTotal=checked(vertexTotal+stat.Vertices);triangleTotal=checked(triangleTotal+stat.Triangles);
                foreach(double x in new[]{stat.Low[0],stat.High[0]})foreach(double y in new[]{stat.Low[1],stat.High[1]})foreach(double z in new[]{stat.Low[2],stat.High[2]})for(int axis=0;axis<3;axis++) {
                    double n=transform[axis]*x+transform[axis+4]*y+transform[axis+8]*z+transform[axis+12];Require(double.IsFinite(n),"nonfinite bounds");minimum[axis]=Math.Min(minimum[axis],n);maximum[axis]=Math.Max(maximum[axis],n);
                }
            }
            foreach(var child in Rows(node["children"]))Visit(child,transform);
        }
        foreach(var node in Rows(scenes[0]?["nodes"]))Visit(node,identity);
        Require(seen.Count==nodes.Count && usedMeshes.Count==meshes.Count && minimum.All(double.IsFinite),"unselected/empty scene content");
        long geometry=usedViews.Aggregate(0L,(sum,i)=>checked(sum+Integer(views[i]?["byteLength"])));
        long Bound(double metres,bool upper) {
            double mm=metres*1000,nearest=Math.Floor(mm+0.5),ulp=metres==0 ? 0 : Math.Pow(2,Math.Floor(Math.Log2(Math.Abs(metres)))-23);
            if(Math.Abs(mm-nearest)<=Math.Min(0.25,Math.Max(0.0001,4*ulp*1000)))mm=nearest;
            return checked((long)(upper ? Math.Ceiling(mm) : Math.Floor(mm)));
        }
        var bounds=minimum.Select(n=>Bound(n,false)).Concat(maximum.Select(n=>Bound(n,true))).ToArray();
        for(int axis=0;axis<3;axis++)if(bounds[axis]==bounds[axis+3]){bounds[axis]--;bounds[axis+3]++;}
        return new([bytes.Length,geometry,vertexTotal,triangleTotal,nodes.Count,materials.Count,pixels],bounds);
    }
    static long ImagePixels(ReadOnlySpan<byte> bytes,string mime)
    {
        if(mime=="image/png") {
            Require(bytes.Length>=24 && BinaryPrimitives.ReadUInt64BigEndian(bytes)==0x89504e470d0a1a0a && BinaryPrimitives.ReadUInt32BigEndian(bytes[12..])==0x49484452,"invalid PNG");
            uint width=BinaryPrimitives.ReadUInt32BigEndian(bytes[16..]),height=BinaryPrimitives.ReadUInt32BigEndian(bytes[20..]);Require(width>0 && height>0,"empty image");return checked((long)width*height);
        }
        Require(bytes.Length>=4 && bytes[0]==255 && bytes[1]==216,"invalid JPEG");int at=2;
        while(at<=bytes.Length-4) {
            Require(bytes[at++]==255,"invalid JPEG segment");int marker=bytes[at++];while(marker==255 && at<bytes.Length)marker=bytes[at++];
            Require(at<=bytes.Length-2,"truncated JPEG");int length=BinaryPrimitives.ReadUInt16BigEndian(bytes[at..]);Require(length>=2 && at<=bytes.Length-length,"invalid JPEG length");
            if(marker is 0xc0 or 0xc1 or 0xc2 or 0xc3) { Require(length>=7,"invalid JPEG frame");int h=BinaryPrimitives.ReadUInt16BigEndian(bytes[(at+3)..]),w=BinaryPrimitives.ReadUInt16BigEndian(bytes[(at+5)..]);Require(w>0 && h>0,"empty image");return checked((long)w*h); }at+=length;
        }
        throw new FormatException("JPEG dimensions unavailable.");
    }
}
