import { createRoot } from 'react-dom/client'
import World from '../src/World'
import { SessionContext, type SessionState } from '../src/session-context'
import { createKeyProvider, b64url } from '../../client/src/key-provider.js'
import '../src/index.css'

// Published account state plus real World controls; signed owner behavior is
// exercised by quod_lobby_setup_tests and the lifecycle/HTTPS acceptance paths.
export async function createLobbySetupFixture() {
  const provider = await createKeyProvider()
  const networkId = new Uint8Array(32).fill(1)
  const agent = { id: 'owner', namespace: 'human:setup-test',
    anchor: b64url(new Uint8Array(32).fill(2)), instanceText: 'me.' }
  const identity = { provider, networkId,
    session: { session_id: 'fixture', expires_ms: Date.now() + 60_000, public_key: b64url(provider.publicKey) } }
  let owner = true, unresolved = 0, completions = 0
  const root = createRoot(document.getElementById('fixture')!)
  function render() {
    provider.accounts = owner ? [{ network: b64url(networkId), namespace: agent.namespace,
      anchor: agent.anchor, instanceText: agent.instanceText }] : []
    const state = { identity, agent, agents: [agent], busy: false, entering: false,
      saved: true, unresolved, error: null,
      finishSetup: async () => { completions++ },
    } as SessionState
    root.render(<SessionContext.Provider value={state}><World /></SessionContext.Provider>)
  }
  render()
  return {
    configure(next: { owner?: boolean; unresolved?: number }) {
      if (next.owner !== undefined) owner = next.owner
      if (next.unresolved !== undefined) unresolved = next.unresolved
      render()
    },
    completions: () => completions,
    dispose: () => root.unmount(),
  }
}
