// Diagnostic-only instruction selection. It grants no input/sample authority.
public static class ViveLookCue
{
    public const string Waiting="WAITING FOR FOCUSED XR TRACKING AND BOTH HANDS\nKeep every control released.";
    public const string Ready="READY";
    public static string Text(bool active,bool visible,bool running,bool nativeFocused,
        bool headHigh,bool leftHighAndVisible,bool rightHighAndVisible,bool released)
        =>active && visible && running && nativeFocused && headHigh &&
            leftHighAndVisible && rightHighAndVisible && released ? Ready : Waiting;
    public static string Compose(bool ready,bool released,string journey)
        =>journey.StartsWith("STOP") || journey.StartsWith("WAITING") || journey.StartsWith("RECONNECT") ? journey :
            ready ? Ready+"\n"+journey : !released ? "INTERACTING — release the control after the gesture." : Waiting;
}
