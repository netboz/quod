// Namespaces are user-supplied and can be long — a user home is `user:` plus a
// 64-character digest. Shortening keeps both ends: the prefix says what kind of
// ontology it is, the tail distinguishes two homes from each other. Callers
// pair this with the full name in a title so nothing is only ever abbreviated.
export function shortNamespace(ns: string) {
  if (ns.length <= 30) return ns
  return `${ns.slice(0, 18)}…${ns.slice(-8)}`
}
