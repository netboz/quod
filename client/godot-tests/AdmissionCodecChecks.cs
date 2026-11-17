using Quod.Client;
using System.Text;
using System.Buffers.Binary;

static class AdmissionCodecChecks
{
    static void Check(bool value,string message) { if(!value)throw new Exception(message);Console.WriteLine("PASS "+message); }
    public static void Run()
    {
        string text=string.Concat(Enumerable.Repeat("node(",96))+"leaf"+new string(')',96);
        Check(Term.Parse(text).ToString()==text,"deep term retains exact structure");
        string name=new string('z',1100);
        Check(Term.Parse(name).ToString()==name,"long symbol retains exact identity");
        string goal="X = <<\""+new string('x',140*1024)+"\">>.", instance="owner(<<\""+new string('i',140*1024)+"\">>).";
        using var key=Identity.Create();var actor=new Actor("admission:test",Identity.Encode(new byte[32]),instance);
        byte[] bytes=Wire.Encode(new byte[32],key.PublicKey,new byte[32],actor,0,1800000000000,goal);
        Check(Identity.Verify(key.PublicKey,bytes,key.Sign(bytes)),"large request signs exact encoded bytes");
        int at=Encoding.UTF8.GetByteCount("quod.agent.goal.v1\0")+96;
        int ns=BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(at));at+=2+ns+32;
        int length=checked((int)BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(at)));at+=4;
        Check(Encoding.UTF8.GetString(bytes,at,length)==instance,"large exact actor text survives uint32 length encoding");at+=length+10;
        length=checked((int)BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(at)));at+=4;
        Check(Encoding.UTF8.GetString(bytes,at,length)==goal&&at+length==bytes.Length,"large exact goal occupies complete signed request");
        foreach(int size in new[]{256,1024,ushort.MaxValue}) {
            var exact=actor with { Namespace=new string('n',size) };
            byte[] request=Wire.Encode(new byte[32],key.PublicKey,new byte[32],exact,0,1800000000000,"true.");
            int offset=Encoding.UTF8.GetByteCount("quod.agent.goal.v1\0")+96;
            Check(BinaryPrimitives.ReadUInt16BigEndian(request.AsSpan(offset))==size &&
                Encoding.UTF8.GetString(request,offset+2,size)==exact.Namespace &&
                Identity.Verify(key.PublicKey,request,key.Sign(request)),"long namespace keeps exact signed UTF8 bytes");
        }
        try {Wire.Encode(new byte[32],key.PublicKey,new byte[32],actor with { Namespace=new string('n',ushort.MaxValue+1) },0,1800000000000,"true.");throw new Exception("Accepted unrepresentable namespace");}
        catch(OverflowException) {Console.WriteLine("PASS uint16 representation overflow refuses");}
        try {Term.Parse(text+" trailing");throw new Exception("Accepted trailing source");}
        catch(FormatException) {Console.WriteLine("PASS trailing projection still refuses");}
    }
}
