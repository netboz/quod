// C4-A1 component, not the full C4 interval analyzer. Input attempts MUST come
// from the independent start inventory, never from the set of retrieved spans.
// The producer's closed allocation metadata accompanies (does not create) rows.
const keyFields = ['window', 'allocation', 'vm', 'owner', 'group', 'ordinal'];
function key(row) {
  const parts = keyFields.map(k => {
    const v = row[k];
    if (typeof v !== 'string' || !v.length || v.length > 256) throw Error(`invalid_${k}`);
    return v;
  });
  if (!/^[1-9][0-9]*$/.test(row.ordinal)) throw Error('invalid_ordinal');
  return JSON.stringify(parts);
}
function identity(x) {
  return Array.isArray(x) && x.length === 2 && /^[0-9a-f]{32}$/.test(x[0]) &&
    /^[0-9a-f]{16}$/.test(x[1]) && BigInt(`0x${x[0]}`) > 0n && BigInt(`0x${x[1]}`) > 0n;
}
function rootKey(row, ids) {
  return JSON.stringify([row.window, row.allocation, row.vm, ...ids]);
}
function exactFloat(hex) {
  if (!/^[0-9a-f]{16}$/.test(hex)) throw Error('invalid_binary64');
  const b = BigInt(`0x${hex}`), e = (b >> 52n) & 2047n;
  if ((b >> 63n) !== 0n || e === 2047n) throw Error('invalid_threshold');
  const m = (b & ((1n << 52n) - 1n)) + (e === 0n ? 0n : 1n << 52n);
  const shift = (e === 0n ? 1n : e) - 1075n;
  return shift >= 0n ? [m << shift, 1n] : [m, 1n << -shift];
}
function threshold(t) {
  if (t?.encoding === 'decimal_integer' && typeof t.value === 'string' && /^(0|[1-9][0-9]*)$/.test(t.value))
    return [BigInt(t.value), 1n];
  if (t?.encoding === 'ieee754_binary64') return exactFloat(t.value);
  throw Error('invalid_threshold');
}
function branch(metadata) {
  const sampler = metadata.sampler;
  if (sampler?.kind !== 'parent_based') return sampler;
  const p=metadata.parent;
  const observed=p?.identity==='none'?'parentless':
    identity(p?.identity)&&typeof p.remote==='boolean'&&typeof p.sampled==='boolean'?
      `${p.remote?'remote':'local'}_${p.sampled?'sampled':'unsampled'}`:'unknown';
  if(observed!==metadata.parent_class) return null;
  const choices = {parentless:'root', remote_sampled:'remote_parent_sampled',
    remote_unsampled:'remote_parent_not_sampled', local_sampled:'local_parent_sampled',
    local_unsampled:'local_parent_not_sampled'};
  return sampler.branches?.[choices[metadata.parent_class]];
}
function expectedSampling(metadata) {
  const selected = branch(metadata);
  if (selected?.kind === 'always_on') return true;
  if (selected?.kind === 'always_off') return false;
  if (selected?.kind !== 'trace_id_ratio' || !identity(metadata.span?.identity)) return null;
  const [num, den] = threshold(selected.id_upper_bound);
  if (num < 0n || num > (1n << 63n) * den) throw Error('invalid_threshold');
  // Pinned SDK 1.7.0: abs(TraceId band (2^63-1)) < stored threshold.
  // IDs and the exact stored binary64 threshold never pass through Number.
  return (BigInt(`0x${metadata.span.identity[0]}`) & ((1n << 63n) - 1n)) * den < num;
}

export function reconcileSampler({starts, roots = [], inventory_complete = false}) {
  if (!Array.isArray(starts) || !Array.isArray(roots) || typeof inventory_complete !== 'boolean')
    throw Error('invalid_inventory');
  const seen = new Set(), byRoot = new Map(), rootRows = new Map();
  const rows = starts.map(s => {
    const k = key(s); if (seen.has(k)) throw Error('duplicate_independent_start'); seen.add(k);
    const meta = s.observation === undefined ? undefined : structuredClone(s.observation);
    const row = {key:k, observation:meta ?? null, issues:[], retrieved:false, policy:'unknown'};
    if (meta?.allocation_kind === 'new_identity' && identity(meta.span?.identity)) {
      const rk = rootKey(s, meta.span.identity);
      byRoot.set(rk, [...(byRoot.get(rk) ?? []), row]);
      row.root_key = rk;
    }
    return row;
  });
  for (const root of roots) {
    for (const k of ['window', 'allocation', 'vm'])
      if (typeof root[k] !== 'string' || !root[k].length) throw Error('invalid_root_identity');
    if (!identity(root.identity)) throw Error('invalid_root_identity');
    const rk = rootKey(root, root.identity);
    rootRows.set(rk, [...(rootRows.get(rk) ?? []), root]);
  }
  for (const [rk, rs] of byRoot) {
    if (rs.length > 1) for (const r of rs) r.issues.push('allocation_identity_reused');
    const retrieved = rootRows.get(rk) ?? [];
    for (const r of rs) {
      // A reused identity does not prove that each distinct attempt exported.
      // Keep ambiguous attempts in the missing/unknown denominator.
      r.retrieved = rs.length === 1 && retrieved.length > 0;
      if (retrieved.length > 1) r.issues.push('duplicate_retrieved_root');
      for (const root of retrieved) {
        if (root.dropped_events !== undefined) {
          if (typeof root.dropped_events !== 'string' || !/^(0|[1-9][0-9]*)$/.test(root.dropped_events))
            throw Error('invalid_dropped_events');
          if (BigInt(root.dropped_events) > 0n) r.issues.push('dropped_events');
        }
        if (root.timestamp_ties === true) r.issues.push('timestamp_ties');
      }
    }
  }
  for (const r of rows) {
    const m = r.observation;
    if (!m) r.issues.push('allocation_observation_missing');
    else if (m.allocation_kind !== 'new_identity') r.issues.push(`allocation_${
      ['borrowed_parent','invalid_or_noop','unknown'].includes(m.allocation_kind) ? m.allocation_kind : 'unknown'}`);
    else if (!identity(m.span?.identity)) r.issues.push('allocation_identity_invalid');
    else if (typeof m.span.sampled !== 'boolean' || typeof m.span.recording !== 'boolean')
      r.issues.push('allocation_flags_unknown');
    else {
      if(m.sampler?.kind==='parent_based' && branch(m)===null)
        r.issues.push('parent_class_disagreement');
      const expected = expectedSampling(m);
      if (expected !== null && expected !== m.span.sampled) r.issues.push('sampler_flag_disagreement');
      else if (!r.issues.includes('allocation_identity_reused') &&
               !r.issues.includes('parent_class_disagreement')) {
        if (m.span.sampled) r.policy = 'does_not_explain_absence';
        else if (expected === false) r.policy = 'excludes_export';
      }
      if (!m.span.sampled && m.span.recording) r.issues.push('record_only');
      if (r.retrieved && !m.span.sampled) { r.issues.push('unsampled_root_retrieved'); r.policy = 'unknown'; }
    }
    if (!r.retrieved) r.issues.push('missing_root');
    if (!inventory_complete) r.issues.push('inventory_incomplete');
    r.issues = [...new Set(r.issues)].sort();
  }
  const missing = rows.filter(r=>!r.retrieved);
  const explained = missing.filter(r=>r.policy==='excludes_export').length;
  const unknown = missing.filter(r=>r.policy==='unknown').length;
  // Exact numerator/denominator counts, not a misleading rounded percentage.
  // Bounds concern observed starts only; incomplete inventory never becomes a
  // fleet/request-wide estimate or an independently justified latency claim.
  return {inventory_complete, denominator:rows.length, missing_roots:missing.length,
    sampler_explained_missing_bounds:{lower:explained,upper:explained+unknown,denominator:missing.length},
    rows, excluded:rows.filter(r=>r.issues.length).map(r=>({key:r.key,reasons:r.issues})),
    orphan_roots:[...rootRows.keys()].filter(k=>!byRoot.has(k))};
}
