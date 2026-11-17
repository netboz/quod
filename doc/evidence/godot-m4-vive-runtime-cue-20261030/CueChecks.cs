using System;
using System.Linq;
using System.Reflection;
int checks=0;
void Check(bool yes,string name) { if(!yes)throw new Exception(name);Console.WriteLine("PASS "+name);checks++; }
string Select(bool[] g)=>ViveLookCue.Text(g[0],g[1],g[2],g[3],g[4],g[5],g[6],g[7]);
var all=Enumerable.Repeat(true,8).ToArray();
Check(Select(all)==ViveLookCue.Ready,"complete current runtime/model/neutral gates select the diagnostic look text");
string[] gates={"active consumer","window visibility","native API running","native Focused","head High","left canonical High plus visible model","right canonical High plus visible model","neutral controls"};
for(int i=0;i<gates.Length;i++) {var missing=(bool[])all.Clone();missing[i]=false;Check(Select(missing)==ViveLookCue.Waiting,"missing "+gates[i]+" withholds READY");}
var parameters=typeof(ViveLookCue).GetMethod("Text")!.GetParameters();
Check(parameters.Length==8 && parameters.All(p=>p.ParameterType==typeof(bool)) && parameters.All(p=>!p.Name!.Contains("application",StringComparison.OrdinalIgnoreCase) && !p.Name.Contains("desktop",StringComparison.OrdinalIgnoreCase)),"desktop focus is absent from cue authority; no false observation can veto runtime readiness");
for(int i=0;i<gates.Length;i++) {
 var withdrawn=(bool[])all.Clone();withdrawn[i]=false;
 Check(Select(all)==ViveLookCue.Ready && Select(withdrawn)==ViveLookCue.Waiting && Select(all)==ViveLookCue.Ready,"current gate withdrawal and restoration are not latched: "+gates[i]);
}
Check(Select(new bool[8])==ViveLookCue.Waiting,"resting or retired missing observations remain WAITING");
Check(typeof(ViveLookCue).GetFields(BindingFlags.Public|BindingFlags.Static).All(f=>f.IsLiteral) && typeof(ViveLookCue).GetMethods(BindingFlags.Public|BindingFlags.Static|BindingFlags.DeclaredOnly).Single().ReturnType==typeof(string),"cue owns only constant text and a pure selection; no mutable owner callback or sample");
Check(ViveLookCue.Ready.Contains("Keep every control released") && !ViveLookCue.Ready.Contains("press",StringComparison.OrdinalIgnoreCase),"look instruction requests released controls and grants no gesture");
Console.WriteLine("M4_RUNTIME_CUE_GATES_COMPLETE checks="+checks+" hardware=false samples=0 domain_writes=0");
