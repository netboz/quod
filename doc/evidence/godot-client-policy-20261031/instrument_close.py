"""Insert payload-free observations into a separately staged diagnostic Main."""
def instrument(text):
    edits = [
        ('backupDialog?.QueueFree(); CloseSession();\n        await Task.WhenAll',
         'backupDialog?.QueueFree(); CloseStage("session.close.begin"); CloseSession(); CloseStage("session.close.returned");\n'
         '        ObserveClose("views",ViewsDisposed); ObserveClose("action",activeAction); ObserveClose("backup",backupWork); ObserveClose("xr.completion",xr.Completion);\n'
         '        CloseStage("owners.await");\n        await Task.WhenAll'),
        ('models.Dispose();await models.Completion;',
         'CloseStage("owners.settled"); models.Dispose(); ObserveClose("models",models.Completion); await models.Completion; CloseStage("models.settled");'),
        ('bool xrStopped=await xr.Shutdown(SignedSession.Now+5000);',
         'CloseStage("xr.shutdown.begin"); bool xrStopped=await xr.Shutdown(SignedSession.Now+5000); CloseStage("xr.shutdown.returned");'),
        ('disposed = true; ReleaseIdentity(); GetTree().Quit(xrStopped ? exitCode : 1);',
         'disposed = true; CloseStage("identity.release.begin"); ReleaseIdentity(); CloseStage("identity.release.returned"); CloseStage("tree.quit.requested"); GetTree().Quit(xrStopped ? exitCode : 1);'),
        ('public override void _ExitTree()\n    {\n',
         'public override void _ExitTree()\n    {\n        CloseStage("tree.exit.entered");\n')]
    original=text
    for before,after in edits:
        assert text.count(before)==1, before
        text=text.replace(before,after)
    restored=text
    for before,after in reversed(edits):
        assert restored.count(after)==1
        restored=restored.replace(after,before)
    assert restored==original
    return text
