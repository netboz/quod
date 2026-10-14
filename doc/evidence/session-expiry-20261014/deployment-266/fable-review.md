**Verdict:** no material production defect in the 0.7.266 candidate. The EUnit stop is an environmental cold‑start overrun of an unchanged test, not a deadlock and not caused by the diff. The proposed test refactor should not be applied now; the smallest next step is one measurement on an idle machine, then a fresh labeled campaign.

## 1. Production review

Verified from the two frozen manifests: the only Erlang production change is the session TTL constant in `src/quod_client_auth.erl`. Every other `src/*.erl`, every `priv/ontologies/*.pl`, every `client/src/*` and every test module except the auth test have identical hashes. UI changes are confined to Session, World, Console, PrologEditor, index.css and two new browser tests.

The expiry and restore logic matches the contract in doc/world.md:

- Expiry hides and inerts a mounted shell keyed on network, signer and actor; the shell is unmounted only on sign‑out. Restore reuses the retained key and resolves outcomes through the outcomes endpoint only, never the proof endpoint.
- World's projection scope now compares network, signer, actor and view, so a same‑key renewal keeps the workspace while reconnecting the view stream, as required.
- Source refresh re‑reads the exact Eidolon through the same opener; the editor keeps its mount key and drops only drafts whose source equals their baseline.

Minor observations, none blocking:

- **Session cap binds sooner.** The per‑node cap of 256 sessions is unchanged while sessions now linger 15 minutes, so sustained login churn hits the cap at two thirds of the previous rate. Pre‑existing hardcoded budget; worth stating in the deploy note.
- **Refresh can silently no‑op.** The opener returns without error when another tool is opening or the request went stale, so the editor reports a successful refresh that did nothing. Low severity.
- **Question drafts are not retained across restore.** The question presentation map is rebuilt on identity change. Consistent with retiring session‑bound work, but the doc promises only source and console drafts; say so.
- **Possible stale clean draft** if a proof cursor was open at expiry: the draft cleanup skips while the old cursor state is still rendered. Unverified; consequence is stale display until a manual refresh, not a wrong write.
- **Manifest gap.** The 266 manifest omits Dockerfile and .dockerignore that the 265 manifest included. If the rolling image is built from them, the frozen inputs do not cover the image definition.
- **Browser selector.** The failed selector matched a label that wraps a select, so the accessible name includes the selected option text. The corrected first‑combobox selector works; a name regex anchored on "Predicate" would be sturdier.

## 2. What happened to EUnit

Facts from the records:

- The run did not merely cancel one test. The timeout killed the group process, cancelling the module and its five enclosing groups, so 420 of 3,974 tests ran.
- Stack samples over the five seconds show the code server alternating between its loop and `read_link` syscalls, and the prometheus supervisor advancing through module loading. That is progress, not a deadlock.
- The cause of the work is prometheus itself: its supervisor init enumerates every module of every loaded application and forces each unloaded one through the code path. That is the "cold module discovery" you saw.
- The test was always a race against EUnit's default five‑second limit. It passed before because it had margin, and it lost the margin this time.

The margin evidence is in the two logs at the same position in the test sequence:

| | Passing run (265) | Failed run (266) |
| --- | --- | --- |
| Time from EUnit start to the Ranch listener report | 70 s | 186 s |
| Ranch report to the router metrics tests | 1.76 s total, including the prometheus cold start | more than 5 s in the cold start alone |
| Other gates (native tests, clippy, UI build) | baseline | 1.8× to 2.7× slower |

Same tests, same order, same modules loaded beforehand, same OTP install path. The machine was simply two to three times slower during the whole 266 campaign. The isolated reruns cannot discriminate: they ran three minutes later on the same loaded machine with nothing preloaded, which is the worst case for this scan.

Hypotheses, not established: concurrent work during the gates (the browser regression campaign with Vite and Chromium, the /tmp copy that filled the tmpfs quota) or another load source. Unknowns: the exact idle cold‑start time, and whether anything else on the host changed between 11:35 and 20:18 (no package update of erlang is recorded in pacman; the asdf install is the same path).

## 3. Process and next action

The gate discipline is fine. What became excessive is diagnosing before comparing: the gate durations already in results.json pointed at the environment, and the deadlock and refactor avenues were pursued first. Two rules would have prevented this: never run a second campaign on the same host while release gates run, and compare every gate's duration against the last green campaign as the first triage step.

Smallest safe next action:

1. On an idle host (confirm nothing else is running), run the unchanged router module alone once as a labeled diagnostic, or time a cold `application:ensure_all_started(prometheus)` in a test shell, and record the number.
2. If it is comfortably under five seconds, start a fresh labeled full sequential campaign (gates‑02) on the idle host. Gates‑01 stays recorded as failed with this triage attached. No test change.
3. Only if the idle cold start is still near the limit is the test structurally broken. Then the right fix is a shared metrics setup that starts prometheus once outside any per‑test limit, applied to all three modules that start it inside a test body (router, foreign log, metrics), as a separate reviewed change with the measured number recorded.

On the proposed refactor as it stands: I would not apply it. It moves environment setup out of the timed body for one module only, which happens to also fix the other two by ordering luck, and it would hide the environmental signal without first measuring it. It cannot qualify gates‑01 in any case; a full campaign is required regardless.
