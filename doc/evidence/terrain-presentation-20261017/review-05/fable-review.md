Reading the review-05 brief, then the frozen delta.

No further reads are needed; everything required is in hand. Final report follows.

References are to the frozen tree `_build/terrain-presentation-20261017/clean-presentation-06/tree/`. Inspection was read-only: patch and file reads, a tree diff against the working tree, recomputation of all 1,214 source manifest hashes, and reading the focused receipts and failure evidence. No build, test, edit, memory update or deployment. The frozen tree matches the working tree for src, client, test, include, doc and priv, and every manifest entry matches on disk.

## Verdict

The correction is sound. It fixes the actual failure, the 1009 close recorded in `credit-diagnostic-03/close.json`, by making the owner respect the existing 512 KiB view frame guard through one pure serializer and measurer, with no new constant, cap, process, queue or compatibility path. Delivery remains one shared credit with exact per-batch and final acknowledgements, fresh-pose alternation between batches, and the same Prolog aggregate allowances. I found no confirmed defect. The departures from my advice are correct: measuring the actual WebSocket envelope against the exact reply guard is right, since `reply` compares the same encoded bytes, and an index-based `through` acknowledgement is simpler than a batch counter while remaining exact.

**Verified.**

- **One serializer and one measurement.** `src/quod_terrain_wire.erl:6-16` is now the only JSON shape for manifests and content, used by `src/quod_client_view.erl:588`. `envelope/1` at lines 20-22 measures a real empty content message with a 43-byte view digest, the real token and `complete:false`, so the true final message is one byte shorter. `chunk_size/1` at lines 48-50 encodes the real entry with the real index and adds the exact unpadded base64url length. `take/4` at lines 38-44 charges the comma separator from the second entry. The sum reproduces the bytes `reply` will measure at `quod_client_view.erl:719-733`, with the same map keys and serializer.
- **Admission before delivery.** `admit/3` at lines 24-32 rejects an oversized manifest and any row that cannot fit alone, and `src/quod_physics.erl:922-930` refuses the manifest through the existing `terrain_unavailable` path, which releases the viewer rather than closing the socket mid-stream. Because every admitted row fits an otherwise empty batch, `batch/2` can never return an empty prefix with remaining rows, so `lists:last` at `quod_physics.erl:946` is safe.
- **Exact acknowledgements and one credit.** `quod_physics.erl:187-188` releases credit only for `complete` against a complete delivery or `through` with the identical last index against that batch; anything else leaves the viewer unchanged, as before, and the `credit := false` head guard discards duplicates. `quod_client_view.erl:80` admits `through` only as a non-negative integer. Remaining indices stay in `terrain_wanted` at line 948 and are consumed prefix by prefix; a new interest or source key builds a new manifest and drops the obsolete remainder after the outstanding ack. The alternation at `deliver_current_frame` is unchanged, so a fresh pose goes out after every acknowledged batch, and no frame can arrive while a batch holds credit.
- **Client.** `client/src/simulation.js:221-224` validates the batch shape, lines 232-235 require the exact missing prefix and that the server's completion flag coincides with full coverage, so an early `complete` or an unrequested index fails closed. Intermediate batches install and render after full verification, readiness is set only on the final batch at lines 257-260, and the stale-interest branches at lines 227-230 and 245-247 release exactly the matching batch ending without installing.
- **Callers.** No remaining user of the removed three-tuple message or `terrain_json`. The GUI example helper at `test/quod_gui_examples_tests.erl:187-196` acknowledges each batch by its last index and completion by `complete`. The owner tests at `test/quod_physics_tests.erl:5214,5228` use the four-tuple.
- **Tests match the claims.** `test/quod_terrain_wire_tests.erl` checks a four-chunk set that exceeds the frame splits into two maximal prefixes, that adding the next row would overflow, and that an oversized row and a 4,000-row manifest are refused. The new socket case from `quod_physics_tests.erl:5274` drives a real signed view over a generated caves field of 27 chunks exceeding 512 KiB, asserts every content frame encodes under the guard with exact indices, byte counts and digests in order, and asserts an early `complete` and a wrong `through` release nothing before the exact ack. The client cases at `client/test/terrain-delivery.test.js:117-158` cover visible partial retention, a frame between batches, readiness only at the end, and a stale partial ack. Receipts: eight Erlang cases and thirty-five client cases passed.
- **Docs** at `doc/voxel-world.md:331-345` and `doc/physics-native.md:815-820` describe the batched contract accurately.

## Confirmed defects

None.

## Material untested risks

- **Browser acceptance on this build.** The deployed walk has not run against clean06. The focused socket case proves batching on the real wire, but the end-to-end movement, freeze-gap and texture assertions in `walk-acceptance.mjs` remain unexercised on a release carrying this code.
- **Wide windows now refuse at the frame rather than at policy.** A Prolog allowance can admit a window whose manifest alone exceeds the frame, roughly two thousand rows. The user then sees a terrain encoding refusal instead of an allowance refusal. Correct and bounded, but the authored `mesh_nodes` allowance is the natural place to keep windows below that, and the refusal text could point at viewing distance as the allowance text does.
- **Prior findings unaffected.** The delta touches neither rendering nor appearance seams, so the earlier carried risks stand unchanged and are not restated.

## Inspection limits

The sequential clean06 gates were still running; `results.json` exists but the brief states not all receipts are passes, and I did not treat them as such. I did not recompute the 27-chunk fixture's sizes myself. The owner appearance helper and the next deployment recipe are explicitly out of scope and were not inferred. This review is consultative, not approval.
