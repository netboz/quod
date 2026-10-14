# Fable review: shared unsigned request identity (expiry-implementation-01, identity-tree)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `identity-manifest.json`, `identity-tree/` against `before/` for the
three changed files. No command or test was run; the parent's gate is the
evidence.

## 1. Verdict

Correct refactor: one pure selector, used by the signed verification path
and the unsigned outcome read, with identical fields and no new authority.
Nothing required.

## 2. Checked

- **One derivation.** `request_identity/2` builds request, bytes, agent blob,
  digest and operation reference from the decoded request. `parsed_evidence/3`
  now takes that map and adds only signature, goal, goal blob and variables,
  so the nine evidence keys are unchanged and the signed path derives
  identity through exactly the same code as the unsigned selector. The
  test pins field equality between the selector and verified evidence.
- **No goal parse, no authority.** The public `request_identity/1` is
  `decode/1` plus `quod_agent_ref:from_text/4`; it never calls the goal
  parser and returns no signature or goal. The test shows a request whose
  goal text is not a goal still yields a selector with the same operation
  reference and a different digest, while `verify/2` refuses it as
  `invalid_goal`. That is the intended asymmetry: identity for lookup,
  validity only through the signed path.
- **Malformed input.** Trailing bytes fail the exact decode; an instance
  text with a variable fails `from_text/4`. Both are tested.
- **Caller.** `outcome_request/1` keeps the `execute` restriction, now as a
  pattern on the selector's request, and returns the same six-tuple as
  before, so `committed_operation_outcome/2` and its monotonic read-set,
  mismatch and veto behaviour are untouched.
- **Size.** The two private copies of the agent-reference and digest
  derivation are gone; the new function is the only one.

## 3. Noted

`request_identity/1` is exported and pure, so it is the natural input for
the future negative token codec as well; nothing in this delta commits to
that and no negative code is present.
