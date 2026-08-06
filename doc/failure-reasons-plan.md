# Failure reasons — standard Erlog diagnostic slice

## Goal

Add two standard Erlog predicates, therefore available in every ontology and
every ordinary Erlog KB:

```prolog
link(bob, tom) :- fail_with_reason(impossible_to_link(bob, tom)).

connect(A, B) :- link(A, B).
connect(A, B) :-
    get_fail_reasons([impossible_to_link(A, B) | _]),
    use_fallback(A, B).
```

`fail_with_reason/1` records its reason then immediately fails. A rule ending
in it can never accidentally succeed. `get_fail_reasons/1` unifies its argument
with the reasons recorded earlier in the current proof, including a failed
alternative that led to the current backtracking alternative.

Every normal predicate call also has a default diagnostic. If it exhausts,
Erlog pushes the dereferenced call term automatically. An explicit reason is
therefore the root cause while the automatically-added calls form its failure
trace:

```prolog
[connect(bob, tom),
 link(bob, tom),
 impossible_to_link(bob, tom)]
```

This work is separate from ontology creation. It is a general Prolog facility,
not a root predicate, a Quod governed predicate, an ACL, or an ontology-local
extension.

## Semantics

- `fail_with_reason(+GroundReason)` records one ground, bounded Prolog term and
  invokes ordinary Prolog failure. It never runs the following goal.
- `get_fail_reasons(?Reasons)` unifies `Reasons` with the current stack and
  continues normally. It does not clear the stack.
- The stack is proof-local, newest-first, and append-only while that proof (or
  selected-scope invocation) continues. It is intentionally retained over backtracking
  and cuts: otherwise a fallback clause could not inspect why the preceding
  alternative failed.
- When a normal interpreted, compiled, or standard predicate exhausts, its
  dereferenced call is pushed automatically. Unbound arguments are frozen as a
  ground `unbound` diagnostic value; failed-branch variables never escape into
  a later alternative.
- `fail_with_reason/1` is not wrapped in an automatic failure frame: its
  explicit argument is its diagnostic. Predicates unwinding above it add their
  own call terms, producing the complete failure trace without a redundant
  `fail_with_reason(...)` entry.
- An exhausted proof returns Erlog's existing `{fail, FinalState}`. Quod maps
  that to bare `fail` when the stack is empty and `{fail, Reasons}` when it is
  non-empty. Successful proof results are unchanged.
- Low-level control failure (`fail/0`, internal cut/findall machinery) does not
  invent a separate reason, but the normal predicate call that exhausts because
  of it does. Failed standard and external predicates are covered by the same
  call boundary as interpreted predicates.
- Reasons deliberately remain visible after a failure used by normal Prolog
  control. In particular, a successful `\+ Goal` retains reasons recorded
  while `Goal` failed, and `findall/3` retains reasons recorded while
  exhausting its generator. This includes both explicit reasons and the
  automatic predicate-call trace. A later `get_fail_reasons/1` can observe
  them. This is a diagnostic history, not branch-transactional state. A
  future provenance-tree feature could distinguish control frames; this slice
  does not claim to do so.
- A remote `::` target's final reasons are merged into the caller's same stack
  before its ask predicate fails, so a local fallback can recover from an
  intentional remote failure too.

There is only the plural reader because it returns the complete stack; no
`get_fail_reason/1` alias is introduced.

## Standard Erlog implementation

This is implemented in `/home/yan/src/erlog` and merged into its `quod`
integration branch. Quod pins the resulting immutable commit, which includes
the existing inter-ontology parser and assert/retract hooks. Do not register
these through `quod_predicates`: they are standard predicates, not external
policy hooks.

1. Add bounded diagnostic state directly to Erlog's `#est{}` record, using
   named fields for the reason stack, byte count, and truncation state. It is
   not a process-dictionary value, nested framework, or global table.
2. Reset that field at the beginning of a fresh `erlog_int:prove_goal/2` run.
   Continuing a successful answer via `erlog_int:fail/1` retains it, which is
   necessary for a demand-driven scope invocation.
3. Add `{fail_with_reason,1}` and `{get_fail_reasons,1}` to
   `erlog_bips:load/1`, with their implementation in `erlog_bips`. The helper
   functions entered as those predicates are named
   `fail_with_reason_predicate/...` and `get_fail_reasons_predicate/...` under
   the project naming rule.
4. `fail_with_reason_predicate` dereferences its argument, requires a ground
   legal Prolog term, records it in the `#est{}` field, then calls
   `erlog_int:fail/1` with the updated state. `get_fail_reasons_predicate`
   uses normal Erlog unification against the stored reason list, then calls
   `prove_body/2`.
5. Quod may read the named `#est{}` fields through `erlog_int.hrl`, which it
   already includes and depends upon. Export only the small Erlog helper needed
   to merge a validated remote stack under the same bounds before failure, so
   the bound/truncation logic is not duplicated.
6. Add one `predicate_failure` choicepoint below each normal predicate
   invocation (interpreted, compiled, or standard built-in), except
   the two diagnostic predicates. Predicate-specific alternatives remain above
   that boundary. When they exhaust, the boundary freezes and pushes the call
   term, then resumes ordinary backtracking. Pending boundaries retain the
   already-dereferenced call by reference rather than deep-copying its
   arguments, and their creation is capped at 256 per proof. Reaching that cap
   records `fail_reasons_truncated` and continues without another diagnostic
   choicepoint. Cuts may discard boundaries only when they discard the
   corresponding call, just like other choicepoints.
7. Remove Erlog's generic `ecall/2` Erlang escape hatch, its continuation
   choicepoint, and its demo/docs. Ontologies may invoke only explicitly
   registered compiled predicates; arbitrary module/function calls from
   ontology content are not part of the execution model.

Erlog choicepoints currently snapshot bindings and variable numbers, then
rebuild from the current `#est{}` while retaining its other fields. Thus the
new state naturally survives backtracking and cut without a bespoke choicepoint
system or a Quod-specific interpreter fork.

## Bounds and validation

The Erlog built-in accepts only a ground legal Prolog data term (atom, number,
binary, compound, or proper/improper list built from those shapes). This also
makes every recorded reason representable by Quod's atom-safe wire codec.

- One reason is limited to 4 KiB in Erlang external-term size.
- The complete stack is limited to 32 KiB.
- At most 256 automatic failure boundaries are created during one proof.
- New reasons are consed in O(1). Merging a remote stack uses a bounded fold,
  never `++`.
- A non-ground reason raises Erlog's normal instantiation error; an invalid
  term raises a domain error.
- At capacity or on an overlarge reason, the predicate still fails normally and
  adds one `fail_reasons_truncated` marker, if absent. It never turns a logical
  failure into unbounded state or a crash.
- Accounting uses `erlang:external_size/1`, so measuring does not serialize the
  term.
- The 32 KiB stack ceiling stays far below Quod's 1 MiB outer transport frame ceiling. A
  compile-time assertion or test pins that relationship so a later bound
  change cannot silently make a valid reason stack unsendable.

The exact record field and bound accounting are internal to Erlog. The exposed
value is only the list of reason terms (and possibly the truncation marker).

## Quod integration

1. Keep `quod_prolog:run_proof_est/2` and `prove_est/2` unchanged: they collapse
   every Erlog `{fail, _FinalState}` to bare `fail`, so consensus membership
   validation and runtime handlers/jobs remain byte-for-byte on their existing
   logical-failure contract. Add one annotated runner used only by the public
   proof worker; internally it has one failure shape, `{fail, Reasons}` (where
   `Reasons` may be empty). The proof-worker reply maps an empty list to public
   `fail` and a non-empty list to public `{fail, Reasons}`. Update tracing and
   the explorer response for that public annotated result.
2. Carry the bounded reason stack in the sequenced proof-scope **complete** event.
   For co-hosted and remote selections, validate that stack through
   `quod_wire_term`, merge it into the caller state through Erlog's exported
   helper, then fail into the caller's normal backtracking path. Transport and
   authorization failures stay on the existing `{error, Reason}` path.
3. Add `{fail, Reasons}` as an ordinary failed proof in
   `quod_directory_control:validate_peer_proof/1`; it must not be mislabeled as
   malformed input.
4. Update `doc/inter-ontology.md` and the explorer contract. This is a
   same-release wire-format change: all test/deployed nodes use the repinned
   Erlog and Quod release; there is no dual protocol or compatibility path.

Adding fields changes the compiled `#est{}` tuple layout. Every Quod module
including `erlog_int.hrl` must be rebuilt against the new Erlog revision, so
the Erlog repin and the corresponding Quod source change land together in one
Quod commit.

No reason enters a transaction, consensus signature, block, ledger, metrics
label, or persistent store.

## Tests

1. Erlog unit tests: direct explicit failure, automatic default reasons for
   interpreted/compiled/standard predicates, a nested call trace, a fallback
   clause observing reasons, cut/backtracking retention, ground freezing of
   variables, fresh-proof reset, invalid input, and the two bounds.
2. Quod EUnit: bare failures remain bare; an annotated local proof returns
   `{fail, Reasons}`; the ordinary runner still returns bare `fail`, proving
   membership and runtime cannot see the widened public result.
3. Ask tests: both co-hosted and remote `::` propagate a target reason into a
   caller fallback; a malformed/oversized completion is rejected before Prolog
   sees it.
4. Regression checks: no reason survives into another proof, no staged write is
   emitted by `fail_with_reason/1`, and no reason appears in a consensus or
   ledger value.

Run Erlog's own tests, then Quod focused EUnit/CT, followed by full EUnit/CT,
Dialyzer, xref, and diff-check before review.

## Non-goals

- No exceptions/catch mechanism or replacement for Erlog errors.
- No persisted failure log, consensus field, global ETS state, or metrics
  cardinality.
- No failure provenance tree or special suppression for negation/findall.
- No compatibility or dual wire protocol.
