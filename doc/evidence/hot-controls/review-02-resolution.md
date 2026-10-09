# Committed-tree review disposition

Claude Fable reviewed Quod commit `61ce04b9c3300df3686f72c58fc12675c689afa6`
and QUIC pin `9832288e2fca0c848bc6453cfb4ee7cbfd59ddd5` against frozen
committed snapshots. Session `9664480f-e1b5-4196-8faa-e315f98ef6e4` read source
only and ran no tests. The [original report](review-02-fable.md) and
[corrected addendum](review-02-addendum.md) are retained in full.

Independent tracing disproved F1: `run_pinned_origin` registers the origin
session through `get_or_open_scope` before running the proof. Adding it again
would double-count the same effect. Fable withdrew this finding. A new signed
same-namespace regression uses an authenticated socket registration, verifies
that two staged pushes fail without admission, then observes a single admitted
push, delivered socket feedback, and chair displacement through the real owner.
It passes against the unchanged Erlang implementation.

F4 was also withdrawn: the scope-session handle is a same-node worker for
another local ontology, distinct from a remote scope. Existing foreign-world
control tests exercise this live discovery path. Removing it would break them.

F2 describes the documented visible failure for invalid authored checkpoint
declarations. Raw fact edits bypassing the supported atomic body-edit action
can leave an inconsistent projection; silently discarding that checkpoint would
introduce a hidden recovery fallback. Fable reassessed it as informational.

F3 was reproduced for both snap and push: a definite proof refusal incorrectly
made the client view unavailable. The client now keeps its view, reports refusal,
and clears the rejected discrete command. A later command uses a new sequence
and signed request. Uncertain replies still suspend further commands without
replay. The regression fails on the prior client and passes with the correction.

Diagnostic attempts are retained separately from release results, including
three mistakes in the new socket fixture: base64 padding, acknowledgement sender,
and expecting an unselected chair in a control-only projection. None changed
production authority or was counted as a production defect reproduction.

Both QUIC fixes passed review. Full release qualification concerns the frozen
integration tree including the already deployed 0.7.254 baseline; it is not a
claim that every shared workspace change belongs to the feature commit.
[Commit delta](commit-delta.json) also records the feature commit's actual source
growth of 2,215 lines, including its required movement/control foundation,
separately from the session's previously reported delta of 20 production lines.
