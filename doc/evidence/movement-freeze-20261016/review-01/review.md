# Review — idle-movement-freeze fix (quod_client_view set_options)

**Verdict: BLOCK** — production delta is sound and approved as written; two defects in the new `signed_client_view_lifecycle_test_` code will fail the focused run. Both are one-line fixes.

## Production diff (`quod_client_view:reply/2`) — APPROVE

Checked against the handler and Cowboy 2.12 semantics:

- **Root cause matches.** `cowboy_websocket` restarts its idle timer only on *inbound* socket data; outbound frames never do. A stationary pilot produces no frames → no acks → no inbound bytes → `timeout` close at 60 s. The fix addresses exactly that.
- **Authorization.** `type => projection` is only ever built in `open_view` (gui), `open_selection` (nonphysical/disabled/…) and `attach_current` — all after `open_result` admission, dependency install and `resume_projection`'s `Expiry > now` check. No pre-admission path reaches `set_options`. `unavailable`/`refresh`/`gui_prepare` replies are untouched. Default handshake timeout unchanged. Confirmed the discarded "before admission" idea is not in the diff.
- **Timing.** `max(0, …)` guarantees `timeout()`. No new `badarg` risk: `open_worker` already ran `erlang:start_timer(Expiry-now, …)` with the same `not_after_ms` and a *larger* duration before any projection exists. Handler `timer`/`candidate_timer`, dependency invalidation and revocation remain the authority; the transport deadline only stops Cowboy pre-empting them.
- **Cowboy contract.** `{[{set_options,#{idle_timeout=>…}}, {text,…}], S}` is a valid 2.12 command-list return; `set_options` is processed before the frame is sent (fine).
- AGENTS.md: no new timer/heartbeat/state/broker; budget is derived from the signed lease, not a constant. +10/−1 is acceptable for this.

## Blockers (test diff, `test/quod_physics_tests.erl`, `signed_client_view_lifecycle_test_`)

**B1 — `expires` override is silently dropped, so `?assert(Idle > 60000)` fails.**
The test calls the 2-arity `simulation_open(F#{expires => Expiry}, Session)`. That wrapper rebuilds a fresh map (`#{namespace=>…,reference=>…,identity=>…}`) before calling the 3-arity, so `expires` (and `space`/`dependencies`) never reach `maps:get(expires,F,now+30000)`. The signed read is 30 s → `Idle ≈ 30000` → first assertion fails; `Idle >= Expiry-now` (≈300000) fails too.
*Minimal fix:* make the wrapper forward `F` instead of rebuilding it:
```erlang
simulation_open(F = #{namespace := Ns, reference := {agent_instance_ref,_,Anchor,_}}, Session) ->
    simulation_open(F#{reference := {agent_instance_ref,Ns,Anchor,viewer}}, Session,
                    {agent_instance_ref,Ns,Anchor,viewer}).
```
(3-arity only reads namespace/reference-anchor/identity plus optional keys, so passing the full map is safe.) Also confirm the test ingress policy admits a 5-minute `not_after_ms`; production does, per the report.

**B2 — `Before` is rebound → runtime `badmatch`.**
`{Before,Expiry} = Open()` binds `Before` (integer) at the top of the `try` body. Later, unchanged: `Before = gen_server:call(Pid, status)` — now a *match* of an integer against a status map → `{badmatch, #{…}}`. No compiler warning; fails at runtime.
*Minimal fix:* rename the first binding, e.g. `{Opened,Expiry} = Open()` and use `Opened` in the three `Idle` assertions.

Both would have surfaced in the focused run; flagging now so the gate run isn't wasted.

## Advisories (consultative, not blocking)

1. **"Absolute deadline" wording is slightly off.** Cowboy stores the value in `opts` and re-arms the *same duration* on every later inbound frame, so the transport window is "≤ lease length of inbound silence", not an absolute instant. Harmless (handler timer is authoritative, client renews at remaining/2 < lease), but the code comment and test name should say "idle window bounded by the lease" rather than "deadline". The test assertions only check the initial value, which is the right thing to check.
2. **Window persists after release.** Once admitted, a socket keeps the extended `idle_timeout` after `refresh`/`unavailable`/expiry — a previously-admitted but currently unauthenticated socket may idle up to the lease length instead of 60 s. Bounded, principal-gated; I'd accept it. Don't add reset code for it unless Yan wants the budget strictly symmetric.
3. **`waiting_for_installation` keeps the 60 s default.** A quiet socket waiting >60 s for a world install still disconnects. Pre-existing, not the reproduced bug; note for the lobby ledger. `projection_deadline/2` is the natural single owner if that is ever folded in.
4. Minor: `binary_to_integer(Expiry)` re-parses the encoded field; `maps:get(expires, S)` is already in state at every projection reply. Cosmetic.
5. Test hygiene: later `Open()` calls in the lifecycle test leave unreceived `{simulation_transport_timeout,…}` messages in the parent mailbox. Harmless (selective receives), fine to leave.

## Not verifiable offline
Whether any other test drives the handler seam directly and still pattern-matches `{reply,{text,_},_}` on a projection (outside the two adapted fixtures). The frozen sequential gate run will show it.

**Resolution to reach APPROVE:** apply B1 and B2, rerun focused tests, then the frozen gates. No production change needed.