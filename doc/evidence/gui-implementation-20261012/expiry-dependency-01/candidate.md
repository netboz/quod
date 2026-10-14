# Executable negative-expiry dependency contract (candidate)

This refines the accepted source-prefix theorem; it is not an implemented wire
contract. No outcome classifications or runtime dispatch are enabled by this file.

## Dependency and validator inputs

Use a separate atom-free read key {2, AgentBytes, OperationId} and token
{OriginalUnsignedRequestBytes, PrefixHeight, CertifiedTimestamp}. The shared
read-set codec checks bounded request syntax, execute mode, exact canonical
agent/id equality, positive bounded height/time and Timestamp > signed expiry.
All containing plans still enforce their ordinary aggregate encoding allowances.
Do not depend on a GUI row or a retraction carrying extra evidence.

The semantic validator also receives its existing authenticated network and exact
scope identity. Decode the bytes, compare network/namespace/genesis anchor, and
check PrefixHeight <= sealed base <= current published parent. The source outcome
index must be fully applied/flushed through PrefixHeight and store exactly that
height's certified timestamp. No wall clock or deadline inferred from a caller.
Reject an operation claim at or before PrefixHeight, regardless of its digest;
storage failure/unready prefix cannot certify expiry.

Important future-row case: an outcome file retained during replay can contain a
claim above PrefixHeight. A *different request* reusing the same agent/id may also
legitimately claim later under a later deadline. Neither invalidates the theorem
that these exact original bytes can never first be admitted after PrefixHeight.
Therefore the validator must check absence through the captured height, not
absence of every future row. Otherwise a purported immutable dependency changes
later without a mutable predicate reservation. A later matching original request
would violate the already-traced admission theorem. Do not silently conflate
these cases with ordinary positive publication visibility.

## One existing index

Retain a compact immutable height->timestamp row in the existing outcome index,
using its existing staged block flush, bounded cache and lifecycle. Extend the
one ordered advance_applied boundary to take certified entry time, with monotonic
validation; no separate service/table, request-time replay or per-read writes.
Use the shared committed projection for both hosted and foreign verified histories.
The published floor continues to gate all reads, including during reopen/rebuild;
a staged time row cannot become observable before the same flush/publication.
Older immutable rows retained during replay remain inaccessible above that floor.
Exact schema/format changes require explicit compatibility review and never
permission to wipe authoritative data or deploy mixed validators.

## Ordinary proof API

Replace committed_operation_outcome(Bytes, Signature, Status) with the common
signature-free committed_operation_outcome(Bytes, Status). The containing ontology
ACL still controls the invoking proof; this observation grants no signing or
execution authority. Derive exact agent/id/digest without materializing request
controlled symbols or parsing the goal. Positive terminal reads keep the existing
key/token and record their dependency before result unification, including a
digest mismatch. Missing claims may return expired only with the dependency above.
A winning claim not yet terminal stays unavailable, including prepared groups;
unsupported independent vectors keep their existing unavailable result.
Unavailable/unknown/error continues to set the monotonic live-bridge sealing veto.
Policy verdicts and reaction matching remain prohibited. Replace actual callers
and tests; do not retain an old/new compatibility fork. The HTTP signed resolution
API is a separate authenticated transport owner and is not implicitly changed.

## Required production evidence

- absent request before/equal/after expiry at actual applied certified timestamps;
- wrong network, namespace, anchor, actor/id, bytes, deadline, height and timestamp;
- unflushed floor, lagging projection, retained future claim and reopen/replay;
- claim before expiry with prepared/unpublished late completion never becomes expired;
- token works in ordinary material apply, atomic prepare and read-only certification;
- result mismatch/backtracking/negation/caught unavailable cannot erase dependency;
- repeated unchanged reads reuse retained index with no replay/rebuild/write/sync;
- a real later certified block advances the available evidence, never a timer;
- retirement/domain/HUD consequences remain one existing atomic transaction.

The retained future-row distinction above still needs independent challenge.
Implementation must not start by treating a local missing row as terminal.
