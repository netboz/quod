import { createRoot } from 'react-dom/client'
import { OntologyInspection } from '../src/OntologyInspection'
import { SessionContext } from '../src/session-context'
import type { SessionState } from '../src/session-context'
import { binary, compound, list, renderTerm, atom } from '../../client/src/prolog-term.js'
import { ontologyTerm } from '../../client/src/world.js'

export function createInspectionFixture() {
  const anchor = new Uint8Array(32).fill(7)
  const identity = { networkId: anchor, provider: { publicKey: anchor, sign: async () => new Uint8Array(64).buffer },
    session: { session_id: 'inspection-fixture', expires_ms: Date.now() + 600000 } }
  const agent = { namespace: 'inspection:owner', anchor, instanceText: 'owner.' }
  const target = { namespace: 'inspection:target', anchor }
  let representation = { kind: 'lens' as const, target,
    lens: { namespace: 'quod:lens', anchor: new Uint8Array(32).fill(8) },
    view: 'ontology_policy', parameters: list([ontologyTerm(target)]) }
  const session = { identity, agent } as unknown as SessionState
  const root = createRoot(document.getElementById('fixture')!)
  let value = 'can_invoke(read, reader, [], target). % é\n', snapshot = value, denied = false, page = 0
  let held = false, release: (() => void) | undefined
  const calls: { url: string; method: string; request?: string }[] = []
  const originalFetch = globalThis.fetch
  globalThis.fetch = async (input, init) => {
    const url = String(input), method = init?.method ?? 'GET'
    const body = init?.body ? JSON.parse(String(init.body)) : null
    calls.push({ url, method, request: body?.request })
    if (method === 'DELETE') return Response.json({ result: 'stopped' })
    if (held) await new Promise<void>(resolve => { release = resolve })
    if (denied) return Response.json({ result: 'fail', reasons: ['not_allowed(<<"inspection:target">>)'] })
    if (url === '/api/goals/cursors') { page = 0; snapshot = value }
    else if (!url.endsWith('/next')) throw new Error('Unexpected inspection operation')
    const bytes = new TextEncoder().encode(snapshot), split = bytes.length - 2
    const more = page++ === 0
    const chunk = compound('source_chunk', [atom(more ? 'more' : 'done'), binary(more ? bytes.slice(0, split) : bytes.slice(split))])
    return Response.json({ result: 'solution', cursor: 'inspection', bindings: [{ View: renderTerm(chunk) }] })
  }
  const unmount = () => root.render(null)
  const mount = () => root.render(<SessionContext.Provider value={session}>
    <OntologyInspection representation={representation} title="View ACL rules" onClose={unmount} />
  </SessionContext.Provider>)
  mount()
  return { calls, target, configure(next: { value?: string; denied?: boolean; otherTarget?: boolean; hold?: boolean }) {
    if (next.value !== undefined) value = next.value
    if (next.denied !== undefined) denied = next.denied
    if (next.hold !== undefined) { held = next.hold; if (!held) { release?.(); release = undefined } }
    if (next.otherTarget) {
      const other = { namespace: 'inspection:other', anchor: new Uint8Array(32).fill(9) }
      representation = { ...representation, target: other, parameters: list([ontologyTerm(other)]) }
      mount()
    }
  }, dispose() { root.unmount(); globalThis.fetch = originalFetch } }
}
