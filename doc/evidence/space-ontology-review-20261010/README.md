# Spaces and ontology ownership: requested Fable review

Yan explicitly requested this review after questioning whether spaces and
classes were being conflated with ontology containers. The latest question,
earlier provisional proposal and precise review scope are in
[the request](review-request.md).

The successful [Fable report](review-02/fable-review.md) is consultative.
Read [the parent's assessment](disposition.md) for checked findings and
corrections, particularly exclusive embodiment, live placement and simulator
handoff. The resulting proposal is
[governed-physics-plan.md](../../governed-physics-plan.md).

## Exact review evidence

- [Source manifest](review-02/source-manifest.json): 28 frozen source/document
  inputs, their byte counts and SHA-256 hashes, request hash, command arguments
  and repository HEAD. The adjacent tree preserves those exact bytes.
- [Receipt](review-02/receipt.json): true child exit 0, success result, 46 turns,
  no changed frozen inputs, start/end timestamps. The review took approximately
  five minutes after successful launch.
- The structured stdout records `claude-fable-5-1` usage. It also records a
  small `claude-haiku-4-5-20251001` usage entry; its role is not identified by
  the response. The requested review model was explicitly `fable`, with no
  fallback model configured. Full stdout and stderr are retained.
- Tools were limited to Read/Grep/Glob, hooks and extra MCP tools disabled.
  The reviewer reported no commands, edits, builds, tests or delegation.

## Retained launch failures and consent

[Review 01](review-01/FAILURE.md) failed in the sandbox before Fable launched.
The escalation was then rejected by automatic approval review, which required
explicit private-source transmission consent; see [the block](approval-block.md).
Yan subsequently approved the exact payload/destination through the interactive
prompt; [the approval record](approval-record.json) retains that response.
The separately labelled review-02 then ran successfully. No failure was erased
or represented as a completed review.

No production changes or runtime acceptance occurred. The source review and
document checks do not establish desktop collision, identity preservation after
activation, or Vive/WebXR acceptance. The integration tracker remains open.

## Followup on ontology instances and existing representations

The [followup request](followup-request.md) captures Yan's later requirements
about ontology instances, existing lenses/Eidolons/marks, ACL exposure and
terminology. The [new Fable report](review-03/fable-review.md) completed with
true child exit 0, 44 turns and no changed frozen inputs; see its
[receipt](review-03/receipt.json) and [35-file manifest](review-03/source-manifest.json).
The review ran for approximately five and a half minutes after launch.
Structured stdout records claude-fable-5-1 and a small auxiliary Haiku usage
entry, with no fallback configured. Read the [followup assessment](followup-disposition.md)
for independently checked corrections and the remaining implementation contract.

The expanded private-source payload was initially [blocked](followup-approval-block.md).
Yan then explicitly [approved transmission](followup-approval-record.json) to the
same external service. The original review, request and frozen tree remain intact.
Only review evidence and its runner changed; the current proposal and production
sources were not edited by this followup.
