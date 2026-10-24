# Final terrain presentation review scope

Read AGENTS.md. Yan explicitly requested Fable validation. Review read-only:
no commands, tests, builds, edits, memory changes or delegation. Return the
COMPLETE report with verdict, confirmed issues versus risks and exact frozen
references. Do not return a short supplement. Consultative, not deployment
approval. The full frozen01 report and receipt are saved in `../review-01`.

Review `_build/terrain-presentation-20261017/review-03/tree`. All 1,212 source
inputs are listed in the source manifest. `changes.patch` is the complete task
delta; `since-review-01.patch` isolates follow-up changes. Do not reread all
unchanged inputs. This freeze precedes its final clean gate campaign.

The bounded-content refactor described in `../review-02/brief.md` is included
unchanged: one content message carries exactly the requested missing indices
within the manifest's admitted aggregate allowance; a fully retained set gets
an empty content message. The old per-chunk/completion wire path is removed.
Five real-owner/signed-socket cases and the client bundle regressions passed.
Production delivery still has ONE outstanding credit. Frames alternate BETWEEN
acknowledged resources, never during a checksum/render await holding credit.
The frozen01 object-identity warning applies to concurrent independent credits,
which this change does not introduce. The delayed-render and native credit
tests check this distinction. Please independently verify it.

Frozen01 findings addressed:

- Sky brightness: an unlit panorama applies brightness to its linear albedo
  once. It no longer also adds emissive colour/texture. Ordinary emissive
  surfaces retain their behavior; the existing shared material owner remains.
- Sky depth order: the existing opaque queue draws declared sky marks first,
  then uses Babylon's normal ordering for other meshes. Sky writes no depth.
  A real-engine test changes its material after foreground creation and checks
  the resulting order. The camera-relative transform and ordinary far plane
  remain. No second geometry or render owner is introduced.
- Renewal: uninterrupted, unexpired renewal preserves visible verified terrain
  only for the identical physical fence AND complete terrain mark declaration,
  including resource allowances. Invalidation, run/binding or allowance changes
  still hide old content. The new registration still awaits its own manifest
  completion before sending commands. Tests drive the actual renewal timer.
- Discrete controls: drive, jump, snap and teleport share one local command
  readiness predicate. Rejected gestures during loading no longer reset held
  input. XR clearance/masking still runs before the drive gate.

The last accepted drive retains its original authored expiry; no speculative
stop or extended lease is added. The batch correction removes hundreds of
round trips that caused multi-second frozen poses, while physics coverage
continues to stop unsafe motion. Actual post-deployment movement timing remains
an acceptance gate, not a claimed result. No physical headset test is claimed.

`client-review-focused-01` covers the changed client seams, including material
custody and ordinary control renewal. `physics-bundle-focused-01` passed all
five owner/socket cases. The previous full campaigns have explicit stop requests
for scope changes, never false passes. Failed fixtures and their causal triage
remain recorded. The latest diagnostic appearance transaction committed using
the agent-owned account and its ordinary signed path, with zero pending writes.
It did not modify Yan's account or world. A visual preview is in preparation.

The preserving rollout and exact owner-signed appearance/source edit are still
being prepared separately. Binary deployment alone does not rewrite founded
ontologies. Do not claim those recipes or live acceptance are reviewed here.
