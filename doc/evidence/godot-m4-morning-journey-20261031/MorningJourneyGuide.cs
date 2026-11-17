using Quod.Client;
using System.Text.Json.Nodes;
using Json=Quod.Client.Json;

// Removable guidance only. Committed outcomes and installed navigation move
// these instructions; this object never sends, submits or grants an action.
public sealed class MorningJourneyGuide
{
    public const string Expired="STOP — Sign-in expired. Rest the headset.\nReconnect explicitly using the SAME saved identity; no operation is replayed.";
    public int Step { get; private set; }
    public Term? First { get; private set; }
    public Term? Nested { get; private set; }
    bool sawDisconnected;
    static bool Same(Term? a,Term? b)=>a!=null && b!=null && a.ToString()==b.ToString();
    public string Observe(JsonNode state,Offer? current,bool available,JsonNode? outcome,bool uncertain=false,bool working=false)
    {
        if(uncertain || state["pending"]?.GetValue<int>()>0)
            return "STOP — Original work is unresolved. Do not Submit again.\nRest the headset and report the status.";
        if(working)return "WAITING — The existing owner is processing the current operation.\nDo not press Submit again.";
        if(state["state"]?.ToString()=="offline") {
            if(Step==9)sawDisconnected=true;
            return "RECONNECT — Connection / identity → Connect.\nUse the SAME saved identity. No new key or registration.";
        }
        if(state["setup"]==null)return "WAITING — Preparing this fresh private demonstration account.";
        var setup=Term.Parse(state["setup"]!.GetValue<string>()).Require("account",6);
        Term? location=state["current_location"]==null ? null : Term.Parse(state["current_location"]!.ToString());
        Term? placed=location?.Name=="placed" ? location.Args[0] : null;
        bool world=state["world_accepted"]?.GetValue<bool>()==true;
        Term? created=null,parent=null;
        if(outcome!=null && Json.Committed(outcome)) {
            var bindings=outcome["bindings"]?.AsArray();
            var result=bindings?.FirstOrDefault(b=>b?["Results"]!=null)?["Results"];
            if(result!=null) {
                var rows=Term.Parse(result.GetValue<string>()).Items;
                created=rows.FirstOrDefault(r=>r.Name=="result" && r.Args[0].Name=="space")?.Args[1];
                var where=rows.FirstOrDefault(r=>r.Name=="result" && r.Args[0].Name=="location")?.Args[1];
                parent=where?.Name=="placed" ? where.Args[0] : null;
            }
        }
        if(Step==0 && available && Same(current?.Subject,setup[2]))Step=1;
        if(Step==1 && created!=null && Same(parent,setup[2])){First=created;Step=2;}
        if(Step==2 && available && Same(current?.Subject,First))Step=3;
        if(Step==3 && world && Same(placed,First))Step=4;
        if(Step==4 && created!=null && !Same(created,First) && Same(parent,First)){Nested=created;Step=5;}
        if(Step==5 && available && Same(current?.Subject,Nested))Step=6;
        if(Step==6 && world && Same(placed,Nested))Step=7;
        if(Step==7 && location?.Name=="unplaced")Step=8;
        if(Step==8 && world && Same(placed,Nested))Step=9;
        if(Step==9 && sawDisconnected && world && Same(placed,Nested))Step=10;
        string Create(string title)=>current?.Name=="create" && available
            ? title+"\nIf shown: Adopt current fields, keeping draft.\nThen: Use current fields and defaults.\nKeep values; RIGHT-EDGE scrollbar; Submit ONCE."
            : title+"\nCreate / operations → Your account storage → space.\nChoose the offered Create space form.";
        return Step switch {
            0=>"1 · INSPECT\nLEFT ray → Current space operations; press/release trigger.\nRead the offered form. Do NOT Submit yet.",
            1=>Create("2 · CREATE A ROOM"),
            2=>"3 · INSPECT THE NEW OBJECT\nThe cube is the space exterior, not a physical wall.\nUse Open result: space to select that exact object and its form.",
            3=>"3 · ENTER THE FIRST ROOM\nSelect Enter space. Adopt fields if shown.\nThen use current fields and defaults; Submit ONCE.\nWait for the committed location; a sent command is not entry.",
            4=>Create("4 · CREATE A NESTED ROOM"),
            5=>"5 · INSPECT THE NESTED OBJECT\nUse the newest Open result: space to select the new object.\nIts ordinary Enter space form must appear.",
            6=>"5 · ENTER THE NESTED ROOM\nSelect Enter space. Adopt fields if shown.\nThen use current fields and defaults; Submit ONCE.\nThe SAME agent changes location. No walking controls in this demo.",
            7=>"6 · LEAVE\nCurrent space operations → Leave space.\nAdopt fields if shown; use current fields and defaults; Submit ONCE.\nLeave makes the agent UNPLACED; it does not guess a parent.",
            8=>"7 · RETURN\nUse the newest Open result: space for the nested room.\nChoose Enter space. Adopt fields if shown.\nThen use current fields and defaults; Submit ONCE.",
            9=>"8 · REST HEADSET\nCreation, entry, Leave and return are complete.\nThe coordinator can now reconnect the SAME saved identity on desktop.\nDisconnect withdraws the signed wand mapping; do not press more controls.",
            _=>"JOURNEY COMPLETE\nThe same committed location survived reconnect.\nRest the headset and report usability. No further Submit or travel."
        };
    }
}
