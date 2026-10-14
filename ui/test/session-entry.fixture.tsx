import { createRoot } from 'react-dom/client'
import { useEffect, useState } from 'react'
import { SessionEntry } from '../src/Session'
import { SessionContext, type SessionState } from '../src/session-context'
import { b64url, createKeyProvider } from '../../client/src/key-provider.js'
import '../src/index.css'

// This fixture supplies published session state; authentication itself is
// exercised through the real auth owner in quod_client_auth_tests.
export async function createSessionEntryFixture() {
  const provider = await createKeyProvider()
  let identity = { provider, networkId: new Uint8Array(32).fill(1),
    session: { session_id: 'initial', expires_ms: Date.now() + 60_000, public_key: b64url(provider.publicKey) } }
  const owner = { id: 'owner', namespace: 'human:owner', anchor: b64url(new Uint8Array(32).fill(3)), instanceText: 'me.' }
  let agent: typeof owner | null = null
  let entering = true, busy = false, error: string | null = null, failRestore = false
  let mounts = 0, restores = 0
  const root = createRoot(document.getElementById('fixture')!)
  function Scene() {
    const [draft, setDraft] = useState('')
    useEffect(() => { mounts++ }, [])
    return <section className="world-shell" aria-label="Test scene">
      <input aria-label="Unsaved work" value={draft} onChange={event => setDraft(event.target.value)} />
    </section>
  }
  const restore = async () => {
    restores++; entering = true; busy = true; error = null; render()
    if (failRestore) error = 'The gateway is unavailable.'
    else identity = { ...identity, session: { ...identity.session, session_id: 'restored-' + restores,
      expires_ms: Date.now() + 900_000 } }
    entering = false; busy = false; render()
  }
  function render() {
    const state = { identity, agent, entering, busy, error, unresolved: 0, restore,
      create: async () => { throw new Error('Expiry must not create an account') } } as SessionState
    root.render(<SessionContext.Provider value={state}><SessionEntry><Scene /></SessionEntry></SessionContext.Provider>)
  }
  render()
  return {
    configure(next: { ready?: boolean; failRestore?: boolean; expired?: boolean }) {
      if (next.ready) { entering = false; agent = owner }
      if (next.failRestore !== undefined) failRestore = next.failRestore
      if (next.expired) identity = { ...identity, session: { ...identity.session, expires_ms: Date.now() - 1 } }
      render()
    },
    stats: () => ({ mounts, restores }),
    dispose: () => root.unmount(),
  }
}
