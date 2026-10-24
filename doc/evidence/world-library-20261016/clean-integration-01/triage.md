# Retained clean-gate failure

Native debug/release tests (57 each), clippy, client tests (214), UI build and
lint passed. EUnit exited 1 after 830.53 seconds. It emitted 33 failure markers;
the bundled progress formatter crashed while printing failure 21, so no complete
test summary exists. `failures-reported.json` indexes the reports actually
printed; the full log is retained. No later gate ran and this is not a pass.
The already-requested stop also preserves the obsolete presentation defaults
in this exact tree; corrected production and preset tests remain outside it.

Inspected causal groups:

- Shared test `committed_kb` loaded the new common policy as height-one domain
  facts, while real projection owners install it in their height-zero base.
  Hand-built signed fixtures therefore carried wrong OCC versions and were
  correctly refused. Replace this duplicate base construction with the real
  `quod_committed_projection:new_est()` and publish only fixture facts at one.
- Exact-read assertions and the old golden producer assumed newly sealed plans
  had no admission-policy dependencies. Preserve full dependency equality and
  old golden decoding/re-encoding, while checking new seals with policy reads.
  Empty source plans retain their zero diff but now have these real reads.
- Capacity fixtures hardcoded the former block/transaction size. Derive their
  large payloads and boundary checks from the common encoding capacity. The
  maximal foreign-payload search must treat semantic-envelope rejection as
  exceeding the upper bound, before block assembly.
- Six lobby jump cases matched the old literal lobby-only physics rule from
  source. Match the generalized rule's motion while retaining all real owner,
  collision, trajectory and contact assertions.

These diagnoses do not account for the formatter's unprinted failures yet.
The next targeted diagnostic run uses verbose reporting and a distinct label;
no failure assertion is removed to manufacture a pass.

Follow-up evidence:

- `../gate-diagnostics-01` passed 419 tests and failed the obsolete Simplex
  fixture that tried to make an individually valid transaction exceed a
  one-item block. The common envelope now guarantees that it fits. Its remaining
  pipeline/coalescing obligations stay in `full_pipeline_parks_and_coalesces_test`;
  transaction, ingress and relay tests retain the encoding refusal obligations.
- `../remaining-boundaries-01` passed the six real jump cases and the corrected
  pipeline test. Its one failure was the maximal foreign-payload fixture's
  signing assumption. Correcting that search then reproduced a real history-page
  overflow in `../foreign-boundary-02`: a full-committee compact witness must
  share the existing 900 KiB page with the material, a tighter carrier than the
  transport frame. Shared material capacity now derives from both carriers.
- `../foreign-boundary-03` passed the maximal accepted transaction, two-block
  proof and 64-signature page encode/decode test. Transport/page limits and
  signature/encoding formats were not raised or changed.

These focused receipts do not replace the next complete frozen campaign.
