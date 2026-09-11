// Offline producer inventory. Counts must be captured independently of exports.
import assert from 'node:assert/strict';
import {ancestryClasses} from './coordinator-ancestry.mjs';

export const OWNER_SCOPE = 'owner_observed_attempt';
export const LEGACY_SCOPE = 'legacy_child_process_lifetime';
const scopes = new Set([OWNER_SCOPE, LEGACY_SCOPE]);
const rootKey = s => `${s.trace_id}/${s.span_id}`;
const bucketKey = r => JSON.stringify([r.allocation, r.namespace, r.group_id, r.duration_scope]);
const nonempty = x => typeof x === 'string' && x.length > 0;
const validRootKey = x => typeof x === 'string' && /^[0-9a-f]{32}\/[0-9a-f]{16}$/.test(x);

export function inventoryRoots(coordinates, inventory) {
  assert(inventory?.schema === 'quod.coordinator-attempt-inventory/v1',
    'Explicit external producer attempt inventory v1 is required; exported roots are not the denominator');
  assert(inventory.provenance?.kind === 'external_producer' && nonempty(inventory.provenance.reference),
    'Inventory must cite independent producer evidence, not exported roots or client request counts');
  assert(nonempty(inventory.scope?.label) && typeof inventory.scope.complete === 'boolean',
    'Inventory must declare the bounded population and whether producer capture is complete');
  assert(Array.isArray(inventory.rows), 'Inventory rows are required, including an explicit empty population');
  const issues = [], expected = new Map(), seenExpectedKeys = new Set();
  for (const r of inventory.rows) {
    assert(nonempty(r.allocation) && nonempty(r.namespace) && nonempty(r.group_id) && scopes.has(r.duration_scope),
      'Each inventory bucket needs allocation/incarnation, namespace, group and duration meaning');
    assert(Number.isSafeInteger(r.expected_attempts) && r.expected_attempts >= 0,
      'Expected attempts must be nonnegative safe integers');
    const key = bucketKey(r);
    assert(!expected.has(key), 'Duplicate inventory bucket');
    if (r.expected_root_keys !== undefined) {
      assert(Array.isArray(r.expected_root_keys) && r.expected_root_keys.length === r.expected_attempts,
        'Exact root keys must cover every expected attempt in the bucket');
      for (const k of r.expected_root_keys) {
        assert(validRootKey(k) && !seenExpectedKeys.has(k), 'Invalid or repeated expected root key');
        seenExpectedKeys.add(k);
      }
    }
    if (r.attempt_evidence !== undefined) {
      assert(Array.isArray(r.attempt_evidence), 'Attempt evidence must be an array');
      const evidenceKeys = new Set();
      for (const e of r.attempt_evidence) {
        assert(r.expected_root_keys?.includes(e.root_key) && !evidenceKeys.has(e.root_key),
          'Attempt evidence must bind a unique independently expected root key');
        evidenceKeys.add(e.root_key);
        assert(e.callback_unwind !== undefined || e.ancestry !== undefined, 'Empty attempt evidence');
        if (e.callback_unwind !== undefined) assert(e.callback_unwind?.verified === true && nonempty(e.callback_unwind.reference),
          'Callback-unwind evidence requires independent verification and a reference');
        if (e.ancestry !== undefined) {
          const a = e.ancestry;
          assert(a?.verified === true && nonempty(a.reference) && ancestryClasses.has(a.class),
            'Ancestry evidence requires a verified class and independent reference');
          assert(a.class === 'retained_parent' ? a.basis === 'retained_context' :
            ['history_only', 'post_down_rebuild'].includes(a.basis), 'Ancestry basis contradicts the declared class');
        }
      }
    }
    expected.set(key, r);
  }
  if (!inventory.scope.complete) issues.push({kind: 'incomplete_coordinator_producer_inventory'});
  const observed = new Map();
  for (const c of coordinates) {
    const s = c.span;
    const key = bucketKey({allocation: s.resource['service.instance.id'] ?? null,
      namespace: s.attributes['quod.namespace'] ?? null,
      group_id: s.attributes['quod.dtx.group_id'] ?? null, duration_scope: c.duration_scope});
    const roots = observed.get(key) ?? [];
    roots.push(rootKey(s));
    observed.set(key, roots);
  }
  const rows = [];
  for (const key of new Set([...expected.keys(), ...observed.keys()])) {
    const r = expected.get(key), root_keys = (observed.get(key) ?? []).sort();
    const missing = r ? Math.max(0, r.expected_attempts - root_keys.length) : null;
    const excess = r ? Math.max(0, root_keys.length - r.expected_attempts) : null;
    const expectedKeys = r?.expected_root_keys;
    const missingKeys = expectedKeys?.filter(k => !root_keys.includes(k)) ?? null;
    const unexpectedKeys = expectedKeys ? root_keys.filter(k => !expectedKeys.includes(k)) : null;
    if (!r) issues.push({kind: 'coordinator_roots_outside_producer_inventory', bucket: JSON.parse(key), root_keys});
    if (missing) issues.push({kind: 'missing_coordinator_roots', bucket: JSON.parse(key), count: missing,
      cause: 'unknown',
      note: 'Unexported, unsampled, disabled, in-flight or lost observation (including possible callback unwind); absence cannot identify the cause and is never evidence of idleness or zero work.'});
    if (excess) issues.push({kind: 'excess_coordinator_roots', bucket: JSON.parse(key), count: excess});
    if (missingKeys?.length || unexpectedKeys?.length) issues.push({kind: 'coordinator_root_identity_mismatch',
      bucket: JSON.parse(key), missing_root_keys: missingKeys, unexpected_root_keys: unexpectedKeys});
    const attempt_evidence = (r?.attempt_evidence ?? []).map(e => {
      const observedRoot = coordinates.find(c => rootKey(c.span) === e.root_key);
      // Independent producer observations are retained as evidence, not inferred
      // missing-root causes and never a substitute for an exported interval.
      if (observedRoot && e.ancestry && observedRoot.ancestry_class !== e.ancestry.class)
        issues.push({kind: 'coordinator_ancestry_evidence_mismatch', root_key: e.root_key});
      return {...e, root_observed: !!observedRoot,
        missing_root_cause: observedRoot ? null : 'unknown'};
    });
    rows.push({bucket: JSON.parse(key), expected_attempts: r?.expected_attempts ?? null,
      observed_roots: root_keys.length, missing_roots: missing, excess_roots: excess, root_keys,
      identity_check: expectedKeys ? 'exact_start_observed_keys' : 'count_only',
      missing_root_keys: missingKeys, unexpected_root_keys: unexpectedKeys, attempt_evidence});
  }
  const expected_attempts = inventory.rows.reduce((n, r) => n + r.expected_attempts, 0);
  assert(Number.isSafeInteger(expected_attempts), 'Total expected attempts exceeds safe integer range');
  return {schema: inventory.schema, provenance: inventory.provenance, scope: inventory.scope,
    rows, issues, summary: {expected_attempts, observed_roots: coordinates.length,
      missing_roots: rows.reduce((n, r) => n + (r.missing_roots ?? 0), 0),
      count_pass: issues.length === 0,
      exact_identity_check_complete: issues.length === 0 && inventory.rows.every(r => r.expected_attempts === 0 || r.expected_root_keys !== undefined),
      root_export_completeness_claim_permitted: false},
    limits: ['Producer evidence is required input, never inferred from exported spans, requests, Begin commits or Complete counts.',
      'Count-only buckets cannot identify which attempt is absent or detect equal-count substitution; optional start-observed root keys strengthen this check.',
      'A count match cannot establish producer capture integrity, sampling/export completeness or causal attribution; independent boundary controls remain required.',
      'Group replacements are separate attempts. Begin adoption is not. Historical Begin loaders are outside coordinate roots.',
      'Starts in tentative callback state count even if a later unwind loses their handles; do not reduce expectations to successfully installed owner rows.',
      'Verified per-attempt callback-unwind or ancestry evidence is independent input, not inferred from missing roots. Count-only inputs cannot attach it to an exact attempt.',
      'Missing root duration and canceled child duration are unknown, never manufactured.']};
}
