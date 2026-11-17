namespace Quod.Client;

// Console lines for reading a session back afterwards: where a pie's opening
// time went, what a headset press reached. Never shown on screen.
public static class Trace
{
    public static void Line(string kind, string detail)
    { Console.WriteLine($"QUOD_TRACE {DateTime.UtcNow:HH:mm:ss.fff} {kind} {detail}"); Console.Out.Flush(); }
}
