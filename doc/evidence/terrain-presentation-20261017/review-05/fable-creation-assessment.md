Reading the triage, the observation around the failure timestamps, and the harness delta.

One last small read to characterize what returns the busy 503, then I will write the assessment.

Nothing further is needed; the assessment follows.

## What the observation proves

- The failure was raised only by the all-sockets error assertion. Every movement, delivery, visibility and appearance metric on the created world passed: 15.17 m excursion, twelve interests, fourteen content messages with two partial batches, largest frame 512,534 bytes under the guard, 1,267 ms maximum pose gap, 267 frames, zero hidden, one sky, 127 terrain occurrences with 152 ready textured surfaces.
- The two anomalies both fall inside the creation-to-entry transition, between the question activation at 276842 and the world entry projection at 293832, and both precede walking.
- The `unavailable` at 285224 was recorded on a socket other than the active world socket. The harness records non-active sockets without `selection`, and the active world socket received normal `active` projections at 284790 and 286946 around it. It coincides to the millisecond with a `projection` on another non-active socket, and the surrounding seconds show the typical burst of `durable_gap` refreshes that follow committed heights.
- The 503 is a console message without URL or body; its position in the array places it between the refreshes at 283798 and 285079, within the same burst.

## What the code says about `view_not_authorized_or_ready`

Two server sites emit it. `src/quod_client_view.erl:236` answers it when the view's signed read did not produce a read outcome at all, which includes a goal that simply failed. `quod_client_view.erl:425` answers it when the read produced no answer. A `gui_question` view's goal is `gui_question_form(Q, View)` at line 207, which requires the `gui_question/6` fact at `priv/ontologies/gui_question.pl:83-85`. Completion through `gui_consume` at lines 127-140 retracts that fact as part of the application's own continuation, and `gui_cancel` does the same. After that, any reopen of the question view fails its read and receives exactly this reason. The client reopens views on every `refresh`, and the question controller's `refresh()` at `client/src/question-controller.js:39-66` reconnects the question stream and, on `unavailable`, only sets a status string. So a single `view_not_authorized_or_ready` on the question socket immediately after the creation commit is the designed retirement path of a completed question, not an authorization failure of the new world view. The new world view itself opened normally at 293832 and streamed.

That is a hypothesis strongly supported by code and timing, not a proven attribution: the record does not say which socket or view kind received it. A world-view open failing `client_world_view` before readiness would produce the same reason, and the record cannot exclude it, although the world socket's uninterrupted `active` projections make it unlikely.

## What the code says about the 503

Signed goal replies map to 503 for exactly four reasons at `src/quod_client_http.erl:344-353`: client auth unavailable, goal ingress busy, symbol budget exhausted, atom table pressure. The busy case comes from the per-key rate gate at `src/quod_client_auth.erl:376-383,500`, which refuses a goal when too many are already in flight for that key. The transition issues many concurrent signed reads at once: several views reopening on `durable_gap`, the question controller's recovery and status reads, and the library panel's world list. A single busy refusal during that burst is the most plausible origin, and the client surfaces it as a thrown error with `status` at `client/src/signed-client.js:321-327` rather than retrying, which is why nothing downstream broke. The other three reasons would normally recur rather than appear once. Which endpoint and which reason remains unknown from this record; the explorer and asset routes also return 503 and are not excluded, though all textures became ready.

## What would distinguish the causes

- Record `kind` and `view` from every socket message, plus a per-socket index and `s.url()`, so an `unavailable` can be attributed to the question, HUD, library or world view. The world socket is already distinguished by the active projection; the others are not.
- Capture HTTP responses with status at or above 400 through `page.on('response')`, including URL and the JSON `error` field, and record the console message's location URL. That names the endpoint and the one of the four reasons.
- Correlate the `unavailable` timestamp with the question's `gui_consume` height: if the question view's reopen that failed was triggered by the refresh carrying the creation commit, retirement is confirmed.
- If the retirement hypothesis holds, the acceptance predicate should treat `view_not_authorized_or_ready` on a question-kind socket after its own submission as expected closure, while keeping it fatal on world and library views. If a busy 503 is confirmed, it is a rate-gate interaction of the transition burst, not a product defect in delivery; whether the client should back off rather than surface it is a separate product question.

## Harness 04 delta

The only change is a trial click at `walk-acceptance-04.mjs:57` that waits for the library's create button to be actionable before reading options, which removes a race in the creation path and asserts nothing new.

## Limits

No command was run; I did not reproduce the transition, open the sockets or read server logs. The attribution above is from code and the retained timeline only. The campaign is correctly retained as failed; this assessment does not convert it into a pass, and the fresh-world diagnostic run is the parent's.
