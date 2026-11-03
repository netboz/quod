// Diagnostic-only instruction selection. It grants no input/sample authority.
public static class ViveLookCue
{
    public const string Waiting="WAITING FOR FOCUSED TRACKING AND BOTH HANDS\nKeep every control released.";
    public const string Ready="LOOK AT BOTH HANDS\nKeep every control released.\nObserve the models once; report afterward.";
    public static string Text(bool active,bool applicationFocused,bool visible,bool running,bool nativeFocused,
        bool headHigh,bool leftHighAndVisible,bool rightHighAndVisible,bool released)
        =>active && applicationFocused && visible && running && nativeFocused && headHigh &&
            leftHighAndVisible && rightHighAndVisible && released ? Ready : Waiting;
}
