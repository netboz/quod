using System;
using System.Threading;
using System.Threading.Tasks;

// Removable observations on the current Godot executor. This owns no close
// work, changes no task/deadline and records no identity, request or draft.
public partial class Main
{
    internal static void CloseStage(string stage, Task? work = null)
    {
        Console.Error.WriteLine("CLOSE_OWNER " + System.Text.Json.JsonSerializer.Serialize(new {
            stage, monotonic = System.Diagnostics.Stopwatch.GetTimestamp(),
            frequency = System.Diagnostics.Stopwatch.Frequency,
            thread = System.Environment.CurrentManagedThreadId,
            context = SynchronizationContext.Current?.GetType().FullName,
            status = work?.Status.ToString()
        }));
        Console.Error.Flush();
    }
    static async void ObserveClose(string stage, Task work)
    {
        CloseStage(stage + ".observed", work);
        try { await work; CloseStage(stage + ".completed", work); }
        catch (Exception error) { CloseStage(stage + "." + error.GetType().Name, work); }
    }
}
