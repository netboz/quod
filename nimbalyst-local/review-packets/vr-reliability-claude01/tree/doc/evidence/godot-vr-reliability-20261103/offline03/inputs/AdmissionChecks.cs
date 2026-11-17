using System.Collections.Concurrent;
using System.Threading.Channels;

// Only the companion's stdin/admission/close block is exercised here. This
// stub cannot create a Godot process, XR session, identity or signed request.
internal sealed partial class AdmissionCase
{
    public readonly TaskCompletionSource visualReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly CloseStub app = new();
    public readonly List<string> reports = [];
    readonly string folder;
    public AdmissionCase(string path) { folder = path; }
    void Observe() { }
    object Snapshot(string? milestone = null) => new { milestone, synthetic = true };
    void Report(string name, object data) { reports.Add(name); }
}

internal sealed class CloseStub
{
    public int Calls;
    public Task CloseApplication() { Calls++; return Task.CompletedTask; }
}

internal static class RenderingServer
{
    static Action? callbacks;
    public static event Action FramePostDraw
    {
        add { callbacks += value; }
        remove { callbacks -= value; }
    }
    public static int Subscribers => callbacks?.GetInvocationList().Length ?? 0;
}

internal sealed class ScriptedInput : TextReader
{
    readonly BlockingCollection<(string? text, int unused)> commands = new();
    readonly Channel<int> reads = Channel.CreateUnbounded<int>();
    public int Active;
    public int Calls;
    public override string? ReadLine()
    {
        if (Interlocked.Increment(ref Active) != 1) throw new Exception("overlapping stdin readers");
        reads.Writer.TryWrite(++Calls);
        try { return commands.Take().text; }
        finally { Interlocked.Decrement(ref Active); }
    }
    public async Task Reading() => await reads.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
    public void Send(string? text) => commands.Add((text, 0));
}

internal static class AdmissionChecks
{
    public static async Task Run()
    {
        int checks = 0;
        TextReader original = Console.In;
        try
        {
            foreach (string phase in new[] { "waiting", "visual", "simultaneous" })
            foreach (string? stop in new string?[] { "finish", "stop", "", null })
            {
                var input = new ScriptedInput();
                Console.SetIn(input);
                string folder = Path.GetFullPath("admission-case-" + checks);
                Directory.CreateDirectory(folder);
                var item = new AdmissionCase(folder);
                // Generated method contains the exact companion04 admission block.
                Task running = item.Run();
                await input.Reading();
                input.Send("status");
                await input.Reading(); // processing evidence, not a sleep
                if (running.IsCompleted || item.app.Calls != 0 || !item.reports.Contains("VR263_STATUS"))
                    throw new Exception("status while waiting must remain open");
                if (phase == "visual")
                {
                    item.visualReady.SetResult();
                    input.Send("status");
                    await input.Reading();
                }
                if (phase == "simultaneous") item.visualReady.SetResult();
                input.Send(stop);
                await running.WaitAsync(TimeSpan.FromSeconds(5));
                if (item.app.Calls != 1 || item.reports.Count(x => x == "VR263_FINISH") != 1 ||
                    RenderingServer.Subscribers != 0 || input.Active != 0)
                    throw new Exception("finish must close once, unsubscribe and retire the stdin reader");
                checks++;
                Console.WriteLine($"PASS exact companion admission {phase}/{stop ?? "EOF"}: one close, no reader/subscriber");
            }
        }
        finally { Console.SetIn(original); }
        Console.WriteLine($"ADMISSION_PASS {checks} synthetic cases; no Godot/XR/application process");
    }
}
