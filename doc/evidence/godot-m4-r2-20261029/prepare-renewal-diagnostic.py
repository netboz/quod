#!/usr/bin/env python3
"""Bounded, argument-free observation supplied only to a diagnostic build."""
import hashlib,json
from pathlib import Path
root=Path.cwd();ev=Path(__file__).resolve().parent;prior=root/'doc/evidence/godot-m4-r1-20261029/inputs'
receipts={}
for name in ['Main','SignedView']:
    original=(prior/('diagnostic01-'+name+'.cs')).read_text();text=original
    def replace(before,after):
        global text
        assert text.count(before)==1,(name,before)
        text=text.replace(before,after)
    if name=='Main':
        replace('context=SynchronizationContext.Current?.GetType().FullName,','context=SynchronizationContext.Current?.GetType().FullName, pending_renewals=SignedView.DiagnosticPendingRenewals,')
    else:
        replace('    public Task? Completion { get; private set; }','''    public static int DiagnosticPendingRenewals;
    static int diagnosticRows;
    void RenewalTrace(string phase) {
        if(Interlocked.Increment(ref diagnosticRows)>256)return;
        Console.Error.WriteLine("M4_R2_RENEWAL "+System.Text.Json.JsonSerializer.Serialize(new {
            phase,kind,pending=DiagnosticPendingRenewals,thread=System.Environment.CurrentManagedThreadId,
            context=SynchronizationContext.Current?.GetType().FullName }));Console.Error.Flush();
    }
    public Task? Completion { get; private set; }''')
        replace('    async Task ExpireOrRenew(long installed, CancellationToken cancellation)\n    {\n        try {','    async Task ExpireOrRenew(long installed, CancellationToken cancellation)\n    {\n        Interlocked.Increment(ref DiagnosticPendingRenewals);RenewalTrace("enter");\n        try {')
        replace('if (renew) { await Open(); await Task.Delay','if (renew) { RenewalTrace("before-open");await Open();RenewalTrace("after-open"); await Task.Delay')
        replace('catch (Exception error) { if (!disposed && installed == version) Discard(error.Message); }','catch (Exception error) { if (!disposed && installed == version) Discard(error.Message); }\n        finally { Interlocked.Decrement(ref DiagnosticPendingRenewals);RenewalTrace("exit"); }')
    p=ev/'inputs'/('renewal-diagnostic01-'+name+'.cs');assert not p.exists();p.write_text(text)
    receipts[name]={'original':str(prior/('diagnostic01-'+name+'.cs')),'original_sha256':hashlib.sha256(original.encode()).hexdigest(),'supplied_sha256':hashlib.sha256(text.encode()).hexdigest(),'observations_only':True,'authority_deadlines_and_scheduling_unchanged':True,'max_log_rows':256}
(ev/'inputs/renewal-diagnostic01-sources.json').write_text(json.dumps(receipts,indent=2)+'\n');print(json.dumps(receipts))
