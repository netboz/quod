**Verdict: GO** for the operator logic as packaged. No blockers in the code. Three items need a yes from the local full job body before `mutate_once.py release` runs. My repo greps this session returned corrupted shell output, so the Erlang call checks below are low confidence and the review rests on the packet.

**What holds up**

- **CAS**: every write uses `EnforceIndex` with the index read from a job that was just verified semantically equal to the expected predecessor, re-verified again after the plan. Plan index is asserted equal. Release cannot start without a maintenance `PASSED.json`.
- **One submission, uncertainty retained**: a failed or lost response records version, index and a no-op plan match against the original job only, then raises. Output dirs are created with `mkdir` without `exist_ok`, and files open with mode `x`, so a rerun cannot resubmit.
- **Stop-before-start**: maintenance waits for all eight original allocations to reach desired=stop and client=complete before the release phase is even allowed. Host-volume placement is re-pinned per index in the probe.
- **Binding**: the clearance hashes the manifest, which hashes every candidate body, the diff record, all baselines and the operator scripts themselves.
- **Read-only probes**: subscription precedes the installed-state snapshot, the deadline is absolute, and the broadcast shape appears to be a 6-tuple with owner first and world fourth, matching the receive pattern. Probes only `prove_ro`, `status`, `snapshot`, `stats`.

**Conditions to confirm from the local body**

1. `update.auto_revert` must be false on the candidate. On a failed release deployment Nomad would otherwise re-place the old image on its own, an unreviewed mutation that bypasses stop-before-start.
2. An `update` stanza must exist. Without one the release watch on `/deployments` can never see `successful` and would time out at the 1200 s deadline with the fleet actually running.
3. Confirm `materialize_principal` only decodes and resolves. The garbled read suggests it does, but the probe must not touch the vault.

**Limits, not blockers**

- No rollback phase exists in the operator. The rollback body is the Count 8 v65 job, so submitting it after release would be a rolling in-place swap. Rollback should be a fresh maintenance then release with the 260 digest under its own clearance.
- The gate `PASSED.json`, `committed-inputs.json` and the sibling 260/259 baselines are checked by content, not bound into the manifest hash.
- Any exception after submission, including a watch read error or the unclamped `wait=30s` near the deadline, exits without `PASSED.json`. Recovery is manual via `uncertain.json`: accepted iff job version equals expected and the no-op plan matched. There is no observe-only resume mode.
- A stopped allocation ending `failed` instead of `complete` stalls maintenance to the deadline. Fail-stop, but recall the unexplained earlier cancellation.
- `history_after.py` fetches the explorer through an unverified TLS context and pins the certificate on a separate connection, so the data path is not bound to the pin. LAN and read-only.
- `personal_owner_after.py` runs the exec with no subprocess timeout; the Erlang side carries the 15 s deadline.
- `prepare_candidate.py` records but does not assert the maintenance-to-release diff. Worth one extra assert: exactly Count 0 to 8 plus the five image paths.

The full eight-node outage during the window, the single-member root committee restart on node0 and the desktop collision acceptance remain outside this review.
