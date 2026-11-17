"""Exact reversible, payload-free milestones in a separately staged Main only."""
def instrument(text):
    edits = [
        ('internal async Task CloseApplication(int exitCode=0)\n    {\n',
         'internal async Task CloseApplication(int exitCode=0)\n    {\n        CloseStage("close.enter");\n'),
        ('backupDialog?.QueueFree(); CloseSession(false);\n        await Task.WhenAll',
         'backupDialog?.QueueFree(); CloseStage("session.close.begin"); CloseSession(false); CloseStage("session.close.returned");\n'
         '        ObserveClose("views",ViewsDisposed); ObserveClose("action",activeAction); ObserveClose("backup",backupWork); ObserveClose("xr.completion",xr.Completion);\n'
         '        CloseStage("owners.await");\n        await Task.WhenAll'),
        ('models.Dispose();await models.Completion;',
         'CloseStage("owners.await.returned"); CloseStage("models.dispose.begin"); models.Dispose(); CloseStage("models.dispose.returned"); ObserveClose("models",models.Completion); await models.Completion; CloseStage("models.await.returned");'),
        ('bool xrStopped=await xr.Shutdown(SignedSession.Now+5000);',
         'CloseStage("xr.shutdown.begin"); bool xrStopped=await xr.Shutdown(SignedSession.Now+5000); CloseStage("xr.shutdown.returned");'),
        ('disposed = true; ReleaseIdentity(); GetTree().Quit(xrStopped ? exitCode : 1);',
         'disposed = true; CloseStage("identity.release.begin"); ReleaseIdentity(); CloseStage("identity.release.returned"); CloseStage("tree.quit.begin"); GetTree().Quit(xrStopped ? exitCode : 1); CloseStage("tree.quit.returned");'),
        ('public override void _ExitTree()\n    {\n',
         'public override void _ExitTree()\n    {\n        CloseStage("tree.exit.entered");\n'),
        ('if (ViewsDisposed.IsCompleted && activeAction.IsCompleted && backupWork.IsCompleted) ReleaseIdentity();',
         'if (ViewsDisposed.IsCompleted && activeAction.IsCompleted && backupWork.IsCompleted) ReleaseIdentity();\n        CloseStage("tree.exit.returned");')]
    original = text
    for before, after in edits:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    restored = text
    for before, after in reversed(edits):
        assert restored.count(after) == 1
        restored = restored.replace(after, before)
    assert restored == original
    return text
