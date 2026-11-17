// Pure checks of the actual removable label compositor. No Godot or IPC.
static class CueCompositionChecks
{
    static int checks;
    static void Check(bool value,string name) {
        if(!value)throw new System.InvalidOperationException(name);
        checks++;System.Console.WriteLine("PASS "+name);
    }
    static void Main() {
        const string work="WAITING — processing; do not Submit again.";
        const string stop="STOP — unresolved original work.";
        const string reconnect="RECONNECT — same saved identity.";
        Check(ViveLookCue.Compose(true,true,work)==work,"physically ready plus semantic WAITING never becomes READY");
        Check(ViveLookCue.Compose(false,false,work)==work,"working instruction stays honest while a control is held");
        Check(ViveLookCue.Compose(true,true,stop)==stop,"STOP dominates physically ready gates");
        Check(ViveLookCue.Compose(true,true,reconnect)==reconnect,"offline reconnect is never a green ready instruction");
        Check(ViveLookCue.Compose(true,true,"1 · INSPECT")=="READY\n1 · INSPECT","eligible actionable instruction retains READY");
        Check(ViveLookCue.Compose(false,true,"1 · INSPECT")==ViveLookCue.Waiting,"missing physical prerequisites withdraw READY");
        Check(ViveLookCue.Compose(false,false,"1 · INSPECT").StartsWith("INTERACTING"),"held-control cue invites only release");
        Check(!ViveLookCue.Compose(true,true,work).StartsWith("READY\n"),"semantic WAITING cannot emit a ready marker");
        System.Console.WriteLine("CUE_COMPOSITION_PASS "+checks);
    }
}
