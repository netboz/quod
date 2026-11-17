// Diagnostic-only instruction selection. It grants no input/sample authority.
public static class ViveLookCue
{
    public const string Waiting="WAITING FOR FOCUSED XR TRACKING AND BOTH HANDS\nKeep every control released.";
    public const string Ready="IF the workspace is readable and reachable:\nPoint LEFT yellow ray at Current space operations.\nFully press/release LEFT trigger ONCE. No Submit.\nOther controls released. If unusable, do not click.\nThen rest headset; report the panel or placement.";
    public static string Text(bool active,bool visible,bool running,bool nativeFocused,
        bool headHigh,bool leftHighAndVisible,bool rightHighAndVisible,bool released)
        =>active && visible && running && nativeFocused && headHigh &&
            leftHighAndVisible && rightHighAndVisible && released ? Ready : Waiting;
}
