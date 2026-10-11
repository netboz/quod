**Verdict: NO-GO on the packet as frozen. One script defect wedges the sequence at the worst moment. GO once `mutate_once.py` is corrected, the manifest re-frozen, and two preflight checks pass.**

**Blocker**

The post-submit equality check in `mutate_once.py` cannot pass for the two ingress phases. The reserve and active bodies are CLI renderings, while the GET after register returns the server's canonical form. Concrete differences: top-level `Migrate` and `Reschedule` keys, `NodePool` empty versus `default`, task `Identity` null versus the default block, `DiskMB` null versus 0, `LogConfig.Enabled`, service `TaskName` empty and `Namespace` absent. The semantic filter strips only index fields, so the assertion fails after the mutation is already accepted. Consequences: the reserve phase creates the ingress job, then aborts before writing its PASSED file, which blocks the release phase while the fleet sits at count 0. The activate phase would abort before watching its own deployment, so nothing confirms Traefik health before the browser reload. The same gap makes `matches_submitted` in the lost-response record unreliable. The candidate phases copy a GET body and should round-trip, but that was never demonstrated either.

Fix: replace the structural compare with Nomad's own no-op plan, and use the same check in the lost-response branch:

```python
confirm,_=request('/v1/job/'+jobid+'/plan',{'Job':desired,'Diff':True});save('plan-after.json',confirm)
assert confirm['JobModifyIndex']==current['JobModifyIndex'] and confirm['Diff']['Type']=='None'
```

Then delete the four generated candidate files, rerun `prepare_candidate.py`, confirm the only changed manifest line is `mutate_once.py`, and record the new manifest hash in the clearance. I cannot compute hashes here.

**Required preflight checks, no design change**

- `history_after.py` fetches blocks through the browser origin at `/explorer/api/block/...`. The before-capture command is not in the packet and that route through the client port is unverified. Run the exact GET now while 259 is live and confirm it returns the frozen tip bodies. If it fails, point both captures at the explorer service.
- The desktop revoke/restore Prolog shows anchor binaries with only the first escape single, as in `\x70\\x82`. If that is literal file content the identity guards fail and the writes are rejected harmlessly. Verify the files before acceptance.

**Verified sound**

- Candidate diffs list only the count and five image fields; volumes, tags, templates, services unchanged; rollback equals version 63.
- Phase expectations Stop 8, Place 1, Place 8, DestructiveUpdate 1 match the reconciler. Scale to zero creates no deployment, so watching allocations is right. The static-port template update on the same node works because the scheduler frees ports of allocations stopped in the same plan.
- Check-index use, double pre-check, main-job guard, indexed blocking reads with one absolute deadline, no resubmission.
- Port reservation ordering holds. A foreign claim of 30519 in the gap surfaces as a failed placement before any mutation.
- Fleet probe binds identities, root anchor, committee size one, all ontologies ready, node-to-volume placement, zero restarts. Certificate compared through the gateway.
- Cold start: node0 is the sole validator and its prestart exits immediately. This is the first stop/start cycle of this volume family, so step 3's checks are load-bearing, and a 259 rollback would be a cold restart too.

**Optional**

- Fleet probe: assert root committed height and catalogue height are at least the 259 values, a cheap no-loss check.
- Personal owner probe: the 15 s installation deadline may be short after a cold start. It is read-only, but exclusive file creation means cleanup before a rerun.
- Allocation `complete` is reported seconds before CNI teardown, so a stale DNAT rule for 30519 may linger briefly. The reserve plan and min-healthy time absorb it.
- If rollback becomes a phase, a rolling image change plans as DestructiveUpdate 1 and Ignore 7, not 8.

Gates-01's unattributed pwrite/datasync remains open and unchanged by this packet. QUD.27 stays open. I could not run the stop notifier in this session.
