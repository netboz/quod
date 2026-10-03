import { createRoot, type Root } from 'react-dom/client'
import { PrologEditor } from '../src/PrologEditor'
import { SessionContext, type SessionState } from '../src/session-context'
import { createKeyProvider, b64url, fromB64url } from '../../client/src/key-provider.js'
import { signedOperationJournal } from '../../client/src/operation-journal.js'
import { readTerm } from '../../client/src/prolog-read.js'
import { binary, compound, formatTerm, renderTerm } from '../../client/src/prolog-term.js'

// Browser boundary fixture: real React, signing and IndexedDB, with explicit
// HTTP responses. Server compilation/authorization are covered by lobby EUnit.
export async function createEditorFixture() {
  const owner = await createKeyProvider()
  const other = await createKeyProvider()
  const encoder = new TextEncoder()
  const decoder = new TextDecoder()
  const bytes = (text: string) => binary(encoder.encode(text))
  const calls: Array<Record<string, unknown>> = []
  const compilerInputs: Array<{ baseline: string; source: string }> = []
  let root: Root | null = null
  const source = 'sample(before).\n'
  const sources = new Map([['sample / 1', source]])
  let holdCatalogue = false
  const catalogueWaiters: Array<() => void> = []
  let accept: 'lost' | 'pending' = 'lost'
  let terminal = false
  let conflict = false
  let cursorNumber = 0
  let lastDraft = source
  const labels = {
    predicate: ['choice', 'Predicate'], new_predicate: ['input', 'New predicate'],
    source: ['editor', 'Source code'], results: ['bindings', 'Edit result'],
    run: ['button', 'Preview changes'], accept: ['button', 'Save changes'],
    stop: ['button', 'Cancel preview'], create: ['button', 'Add predicate'],
    resolve: ['button', 'Check saved outcome'],
  }
  const view = { title: 'Prolog code', fields: Object.entries(labels).map(([role, [kind, label]]) => ({ role, kind, label })) }
  const response = (body: unknown) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } })
  const journal = signedOperationJournal()
  const previousFetch = window.fetch
  window.fetch = async (input, init) => {
    const path = String(input)
    const body = JSON.parse(String(init?.body ?? '{}'))
    const row: Record<string, unknown> = { path, body }
    calls.push(row)
    if (body.request) {
      const request = fromB64url(body.request)
      const signingKey = request.slice(19 + 32, 19 + 64)
      const publicKey = await crypto.subtle.importKey('raw', signingKey, { name: 'Ed25519' }, false, ['verify'])
      if (!await crypto.subtle.verify('Ed25519', publicKey, fromB64url(body.signature), request)) throw new Error('fixture received invalid signature')
      // Request grammar is frozen: domain, three identity fields, namespace,
      // genesis anchor, instance, mode/version/deadline, then source bytes.
      const data = new DataView(request.buffer, request.byteOffset, request.byteLength)
      let offset = 19 + 96
      offset += 2 + data.getUint16(offset)
      offset += 32
      offset += 4 + data.getUint32(offset)
      offset += 10
      const length = data.getUint32(offset)
      row.goal = decoder.decode(request.slice(offset + 4, offset + 4 + length))
      row.signatureVerified = true
    }
    if (path === '/api/goals/read') {
      const goal = String(row.goal)
      if (goal.includes('prolog_predicates(')) {
        const oldCatalogue = () => response({ result: 'ok', bindings: [{ Predicates: "['/'(sample,1)]" }] })
        if (holdCatalogue) return new Promise<Response>(resolve => catalogueWaiters.push(() => resolve(oldCatalogue())))
        return oldCatalogue()
      }
      if (goal.includes('prolog_source(')) {
        const call = readTerm(goal.slice(goal.indexOf('prolog_source('), -2)) as any
        return response({ result: 'ok', bindings: [{ Source: renderTerm(bytes(sources.get(formatTerm(call.args[1])) ?? '')) }] })
      }
      if (goal.includes('prolog_clauses(')) {
        const call = readTerm(goal.slice(goal.indexOf('prolog_clauses('), -2)) as any
        const draft = decoder.decode(call.args[0].value)
        if (draft !== '% Kept until a structural edit\nsample(one).\nsample(two).\n') throw new Error('unexpected cards fixture source')
        return response({ result: 'ok', bindings: [{ Clauses: '[sample(one),sample(two)]' }] })
      }
      if (goal.includes('prolog_edit_goal(')) {
        const call = readTerm(goal.slice(goal.indexOf('prolog_edit_goal('), -2)) as any
        const [target, , baseline, draft] = call.args
        lastDraft = decoder.decode(draft.value)
        compilerInputs.push({ baseline: decoder.decode(baseline.value), source: lastDraft })
        const [ns, anchor] = target.args
        const edit = compound('::', [ns, compound(',', [compound('current_ontology_identity', [ns, anchor]),
          compound('transaction', [compound('assertz', [compound('saved_source', [draft])])])])])
        return response({ result: 'ok', bindings: [{ Edit: renderTerm(edit) }] })
      }
      throw new Error(`unexpected read ${goal}`)
    }
    if (path === '/api/goals/cursors') {
      if (conflict) return response({ result: 'fail', reasons: ['edit_conflict(sample/1)'] })
      const cursor = `edit-${++cursorNumber}`
      return response({ result: 'solution', cursor, height: 4, bindings: [] })
    }
    if (/\/api\/goals\/cursors\/edit-\d+\/accept$/.test(path)) {
      if (accept === 'lost') throw new TypeError('fixture interrupted Save reply')
      return response({ result: 'pending', ns: 'human:owner', anchor: '09'.repeat(32),
        coordinator: '12'.repeat(32), coordinator_admission: '34'.repeat(32), group_id: '56'.repeat(32) })
    }
    if (path === '/api/goals/outcomes') {
      const saved = (await journal.list()).find(item => item.request === body.request)
      if (!saved || saved.signature !== body.signature) throw new Error('lookup did not retain exact signed request')
      if (terminal) sources.set(String((saved.context as any).indicator), String((saved.context as any).source))
      return response({ result: 'operation_outcome', status: terminal ? 'committed' : 'pending', terminal })
    }
    if (/\/api\/goals\/cursors\/edit-\d+$/.test(path) && init?.method === 'DELETE') return response({ result: 'stopped' })
    throw new Error(`unexpected HTTP endpoint ${path}`)
  }
  const mount = (options: { key?: string; actor?: string; agentAnchor?: number; targetAnchor?: number; session?: string } = {}) => {
    root?.unmount()
    root = createRoot(document.getElementById('fixture')!)
    const identity = { provider: options.key === 'other' ? other : owner,
      networkId: new Uint8Array(32).fill(1), session: { session_id: options.session ?? 'session',
        expires_ms: Date.now() + 60_000, public_key: b64url(owner.publicKey) } }
    const agent = { id: options.actor ?? 'owner', namespace: 'human:owner',
      anchor: b64url(new Uint8Array(32).fill(options.agentAnchor ?? 9)), instanceText: `human_user(${options.actor ?? 'owner'}).` }
    const workspace = { target: { namespace: 'personal:lobby', anchor: new Uint8Array(32).fill(options.targetAnchor ?? 7) },
      tools: { namespace: 'quod:prolog', anchor: new Uint8Array(32).fill(8) }, view }
    root.render(<SessionContext.Provider value={{ identity, agent, error: null } as SessionState}>
      <PrologEditor workspace={workspace} onClose={() => { root?.unmount(); root = null }} scene={null} visible={false} />
    </SessionContext.Provider>)
  }
  return { mount, calls, compilerInputs, rows: () => journal.list(),
    heldCatalogues: () => catalogueWaiters.length,
    releaseCatalogue() { holdCatalogue = false; for (const release of catalogueWaiters.splice(0)) release() },
    configure(options: { accept?: 'lost' | 'pending'; terminal?: boolean; conflict?: boolean; holdCatalogue?: boolean }) {
      if (options.accept) accept = options.accept
      if (options.terminal !== undefined) terminal = options.terminal
      if (options.conflict !== undefined) conflict = options.conflict
      if (options.holdCatalogue !== undefined) holdCatalogue = options.holdCatalogue
    },
    close() { root?.unmount(); root = null },
    dispose() { root?.unmount(); root = null; window.fetch = previousFetch },
  }
}
