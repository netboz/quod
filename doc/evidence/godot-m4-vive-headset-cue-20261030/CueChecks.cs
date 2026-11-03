using System;
using System.Linq;
using System.Reflection;
int checks=0;
void Check(bool yes,string name) { if(!yes)throw new Exception(name);Console.WriteLine("PASS "+name);checks++; }
string Select(bool[] g)=>ViveLookCue.Text(g[0],g[1],g[2],g[3],g[4],g[5],g[6],g[7],g[8]);
var all=Enumerable.Repeat(true,9).ToArray();
Check(Select(all)==ViveLookCue.Ready,"actual complete diagnostic gates select only the released-controls look instruction");
string[] gates={"active","application focus","presentation visible","native running","native focus","head High","left canonical High and model mesh visible","right canonical High and model mesh visible","all controls released"};
for(int i=0;i<gates.Length;i++) {var missing=(bool[])all.Clone();missing[i]=false;Check(Select(missing)==ViveLookCue.Waiting,"missing "+gates[i]+" selects honest WAITING");}
var lost=(bool[])all.Clone();lost[1]=false;
Check(Select(all)==ViveLookCue.Ready && Select(lost)==ViveLookCue.Waiting,"readiness is withdrawn on the next observation after focus loss; no latch");
lost=(bool[])all.Clone();lost[7]=false;
Check(Select(all)==ViveLookCue.Ready && Select(lost)==ViveLookCue.Waiting,"readiness is withdrawn when either model/hand gate disappears");
Check(Select(new bool[9])==ViveLookCue.Waiting,"missing head and both hands while resting is WAITING");
Check(typeof(ViveLookCue).GetFields(BindingFlags.Public|BindingFlags.Static).All(f=>f.IsLiteral) && typeof(ViveLookCue).GetMethods(BindingFlags.Public|BindingFlags.Static|BindingFlags.DeclaredOnly).Single().ReturnType==typeof(string),"pure cue exposes only text and constants; no sample, domain callback or mutable owner");
Console.WriteLine("M4_CUE_GATES_COMPLETE checks="+checks+" hardware=false samples=0 domain_writes=0");
