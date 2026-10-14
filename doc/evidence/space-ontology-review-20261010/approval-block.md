# External review approval block

The escalated review-02 launch was rejected before execution by automatic
approval review. No review-02 directory or Fable result was produced by that
request.

Recorded reason: the requested launcher would send private repository/design
material to external Fable/Claude, and the reviewer required explicit approval
of this payload and destination beyond the user's request for a Fable review.
Do not bypass this refusal through another process or session launcher.

The pending approval asks to send only the 28 files enumerated in run-review.mjs
and review-request.md to the configured external Claude Fable service. It
excludes credentials, private keys, live account state and unrelated workspace
files. The reviewer is restricted to Read/Grep/Glob in the frozen review tree.
