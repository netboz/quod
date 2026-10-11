# Independent resolution of Fable's renewal plan review

Fable reviewed the frozen first plan and relevant source excerpts using model
`claude-fable-5-1`; the child exited zero and the packet hash was unchanged.
Its verdict is conditional GO. This resolution records the implementation
boundary before production edits; the original plan and review remain intact.

Accepted corrections:

- The existing `open` command must recognize an unchanged, ready installed
  request before releasing it. Store its exact request scope, including session,
  signing principal, full anchored actor, world, instance and mode/navigation
  goal. Matching only source anchor and instance would miss an actor or mode
  change. There remains one opening worker, not a separate renewal executor.
- Keep the old timer armed and a separate bounded candidate timer. Initial
  opening and candidate completion/cancellation must use their actual lifetime
  markers. Promotion cancels the old timer; release cancels both. Handle the
  candidate timer explicitly even though its deadline is normally later:
  stale timer delivery and cleanup must be harmless, not assumed impossible.
- An equal dependency set retains exact follows and monitors. Fresh asynchronous
  local snapshots reuse the existing snapshot owner before installation; do not
  assume mailbox ordering between different senders proves current readiness.
  Retained foreign progress remains governed by its acknowledged owner notices
  and owner incarnation. A changed dependency set retires the old projection
  before the ordinary subscribe-before-snapshot path; nothing is leaked.
- Reuse the existing physics monitor and replace native delivery reference and
  random registration atomically. Set credit false and tick to the returned
  current frame; its new acknowledgement releases credit. Old frames/acks are
  fenced. The socket checks the original old-view expiry before and after the
  replacement operation and releases the actual returned reference on failure.
- Replace `watch/2` with `watch/3` (owner PID, expected physical selection,
  previous reference or `none`). The socket retains ownership of view expiry;
  do not introduce another view lease into physics or change admitted input
  deadlines. Verify the same socket/reference and complete unchanged installed
  selection in that owner. Its existing `current_projection/2` compares only
  fence, structure and incarnation, so old admitted rows continue until their
  unchanged input expiry after registration rotation.
- Keep command epoch and any discrete-command obligation across a successful
  renewal. A still-pending old HTTP command must report uncertainty normally.
  A new projection cannot suppress that failure or reset sequence backwards.
  A definite stale-registration refusal remains a normal `fail` with reasons;
  it can retire the original discrete gate. Renewal itself never replays one.
- Controlled navigation already preserves held keys and calibration when it
  receives the same physical binding without an intervening null update.
  Retained input and the existing half-lease sampling provide continuity;
  no new navigation writer or special immediate resend is needed.

Deliberate conservative choice: a candidate that cannot be authorized or
installed stops the view through the existing failure path. The review suggested
keeping the old view and adding a candidate-tagged error; that availability
enhancement is unnecessary to correct successful unchanged renewal and would
add a new error protocol. Do not hide a fresh denial or keep movement after
uncertain command failure. Failure is not scheduled for an automatic retry.

The new owner regression must cover this fail-closed choice alongside expiry,
revocation, changed owner/physical fence, pending discrete controls, stale replies,
retained subscriptions and zero rebuild/persistence work on unchanged renewal.
No compatibility branch or obsolete watch export remains. The implementation
will receive a separate Fable review and independent validation before release.
