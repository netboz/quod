// Classify only the retained-context fact exported by the producer.
// History-only recovery and reconstruction after DOWN are not distinguishable
// from a genuinely parentless root without independent producer evidence.
export const ancestryClasses = new Set(['retained_parent', 'no_retained_parent']);
const validParent = p => typeof p === 'string' && /^[0-9a-f]{16}$/.test(p) && !/^0+$/.test(p);
const noParent = p => p === null || p === undefined || p === '' || /^0{16}$/.test(p);

export function coordinatorAncestry(span, owned, issues) {
  if (!owned) return {ancestry_class: 'legacy_or_unknown', ancestry_note:
    'No B ancestry classification is inferred from legacy parent fields.', ancestry_association_eligible: true};
  const declared = span.attributes['quod.dtx.ancestry'];
  const key = `${span.trace_id}/${span.span_id}`;
  if (!ancestryClasses.has(declared)) {
    issues.push({kind: 'missing_or_invalid_coordinator_ancestry', key});
    return {ancestry_class: 'unknown', ancestry_note:
      'The retained-context class is absent or invalid; a parent field is not substituted for the producer declaration.',
      ancestry_association_eligible: false};
  }
  const consistent = declared === 'retained_parent' ? validParent(span.parent) : noParent(span.parent);
  if (!consistent) issues.push({kind: 'coordinator_ancestry_parent_mismatch', key, declared});
  return {ancestry_class: declared, ancestry_association_eligible: consistent,
    ancestry_origin: 'not_inferred',
    ancestry_note: declared === 'no_retained_parent' ?
      'No retained parent context. History-only recovery or a rebuilt owner row (including after DOWN) remain indistinguishable without independent provenance; no former caller is reconstructed.' :
      'A valid original parent context was retained. This is not by itself proof of a client caller or preservation across every later rebuild.'};
}
