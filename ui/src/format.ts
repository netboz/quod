// Small display helpers shared by the components.

// tx ids share a node-hash prefix — the tail is the distinguishing part, keep both ends
export const shortHex = (s: string, n = 14) =>
  s.length <= n ? s : s.slice(0, n - 6) + '…' + s.slice(-4)

export function ago(ms: number, now: number): string {
  if (!ms) return '—'
  const s = Math.max(0, Math.round((now - ms) / 1000))
  if (s < 60) return `${s}s ago`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ago`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ${m % 60}m ago`
  return new Date(ms).toLocaleDateString()
}

export const timestamp = (ms: number) => (ms ? new Date(ms).toLocaleString() : '—')
