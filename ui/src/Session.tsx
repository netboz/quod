import { useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import {
  clearActiveKeyProvider,
  b64url,
  createKeyProvider,
  downloadEncryptedKeyProvider,
  hasLocalKeyProvider,
  loadActiveKeyProvider,
  loadLocalKeyProvider,
  localKeyMatches,
  saveVerifiedLocalKeyProvider,
  storeActiveKeyProvider,
} from '../../client/src/key-provider.js'
import {
  assertCrypto,
  authenticateKey,
  resolveSignedOperations,
} from '../../client/src/signed-client.js'
import type { SignedIdentity } from '../../client/src/signed-client.js'
import {
  activeAgentReference,
  agentReferences,
  saveAgentReference,
  selectAgentReference,
} from '../../client/src/agent-references.js'
import { SessionContext, useSignedSession } from './session-context'

export function SignedSessionProvider({ children }: { children: ReactNode }) {
  const [identity, setIdentity] = useState<SignedIdentity | null>(null)
  const [agents, setAgents] = useState(agentReferences)
  const [agent, setAgent] = useState(activeAgentReference)
  const [busy, setBusy] = useState(false)
  const [saved, setSaved] = useState(false)
  const [unresolved, setUnresolved] = useState(0)
  const [error, setError] = useState<string | null>(null)

  const login = async (providerPromise: ReturnType<typeof createKeyProvider>) => {
    setBusy(true)
    setError(null)
    try {
      assertCrypto()
      const next = await authenticateKey(await providerPromise)
      setIdentity(next)
      // Same identity store as the client page of this origin, so signing in
      // on either surface signs in on both.
      try {
        await storeActiveKeyProvider(next.provider)
      } catch {
        /* a browser that keeps nothing still works for this session */
      }
      setSaved(localKeyMatches(next.provider))
      try {
        const recovered = await resolveSignedOperations(next)
        setUnresolved(
          recovered.filter(({ reply }) => reply?.terminal !== true).length,
        )
      } catch {
        setUnresolved(0)
        setError('Signed in, but durable write storage is unavailable. Reads remain available; writes are disabled.')
      }
    } catch (reason) {
      setError(message(reason))
    } finally {
      setBusy(false)
    }
  }

  const create = () => login(createKeyProvider())

  const signOut = async () => {
    if (identity && !saved && !window.confirm(
      'This identity has no encrypted backup saved in this browser.\n\n'
        + 'Export it before signing out unless you already have a key file.\n\n'
        + 'Sign out anyway?',
    )) return
    setBusy(true)
    try {
      await clearActiveKeyProvider()
    } catch {
      /* nothing kept it */
    }
    setIdentity(null)
    setSaved(false)
    setUnresolved(0)
    setError(null)
    setBusy(false)
  }

  // Resume the browser's identity before anything is clicked. Reaching the
  // Explorer from the client must not ask anyone to log in a second time.
  const resumed = useRef(false)
  useEffect(() => {
    if (resumed.current) return
    resumed.current = true
    void (async () => {
      const provider = await loadActiveKeyProvider()
      if (provider) await login(Promise.resolve(provider))
    })()
  }, [])

  const unlock = async () => {
    const passphrase = window.prompt('Passphrase for your saved Quod identity')
    if (passphrase === null) return
    await login(loadLocalKeyProvider(passphrase))
  }

  const save = async () => {
    if (!identity) return
    const passphrase = window.prompt('Choose a passphrase of at least 12 characters')
    if (passphrase === null) return
    const confirmation = window.prompt('Repeat the passphrase')
    if (confirmation !== passphrase) {
      setError('The passphrases did not match. Nothing was saved.')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await saveVerifiedLocalKeyProvider(identity.provider, passphrase)
      setSaved(true)
    } catch (reason) {
      setError(message(reason))
    } finally {
      setBusy(false)
    }
  }

  const exportKey = async () => {
    if (!identity) return
    const passphrase = window.prompt('Passphrase for the encrypted key file (at least 12 characters)')
    if (passphrase === null) return
    const confirmation = window.prompt('Repeat the passphrase')
    if (confirmation !== passphrase) {
      setError('The passphrases did not match. Nothing was exported.')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await downloadEncryptedKeyProvider(
        identity.provider,
        passphrase,
        `quod-key-${fingerprint(identity)}.quodkey`,
      )
    } catch (reason) {
      setError(message(reason))
    } finally {
      setBusy(false)
    }
  }

  const addAgent = () => {
    const namespace = window.prompt('Agent ontology namespace')
    if (namespace === null) return
    const anchor = window.prompt('Agent ontology genesis anchor (base64url)')
    if (anchor === null) return
    const instanceText = window.prompt('Ground agent instance term', 'human_user(me).')
    if (instanceText === null) return
    try {
      const next = saveAgentReference({ namespace, anchor, instanceText })
      setAgents(agentReferences())
      setAgent(next)
      setError(null)
    } catch (reason) {
      setError(message(reason))
    }
  }

  const selectAgent = (id: string) => {
    try {
      selectAgentReference(id)
      setAgent(activeAgentReference())
      setError(null)
    } catch (reason) {
      setError(message(reason))
    }
  }

  return (
    <SessionContext.Provider
      value={{ identity, agent, agents, busy, saved, unresolved, error,
        create, unlock, save, exportKey, signOut, addAgent, selectAgent }}>
      {children}
    </SessionContext.Provider>
  )
}

export function SessionControls() {
  const session = useSignedSession()
  if (session.identity) {
    return (
      <div className="flex flex-wrap items-center gap-2 text-xs">
        <span className="font-mono text-cream/80">
          key {fingerprint(session.identity)}
        </span>
        {session.agents.length > 0 && (
          <select
            value={session.agent?.id || ''}
            onChange={(event) => session.selectAgent(event.target.value)}
            className="rounded-md border border-cream/40 bg-teal px-2 py-1 text-cream"
          >
            {session.agents.map((agent) => (
              <option key={agent.id} value={agent.id}>{agent.namespace} · {agent.instanceText}</option>
            ))}
          </select>
        )}
        <button
          type="button"
          onClick={session.addAgent}
          className="rounded-md border border-gold/60 px-2 py-1 text-gold hover:bg-teal-light"
        >
          Add agent
        </button>
        {!session.saved && (
          <button
            type="button"
            disabled={session.busy}
            onClick={() => void session.save()}
            className="rounded-md border border-gold/60 px-2 py-1 text-gold hover:bg-teal-light disabled:opacity-40"
          >
            Save encrypted key
          </button>
        )}
        <button
          type="button"
          disabled={session.busy}
          onClick={() => void session.exportKey()}
          className="rounded-md border border-cream/40 px-2 py-1 text-cream hover:bg-teal-light disabled:opacity-40"
        >
          Export encrypted key
        </button>
        <button
          type="button"
          disabled={session.busy}
          onClick={() => void session.signOut()}
          className="rounded-md border border-cream/40 px-2 py-1 text-cream hover:bg-teal-light disabled:opacity-40"
        >
          Sign out
        </button>
        {session.unresolved > 0 && (
          <span className="text-gold-soft">
            {session.unresolved} unresolved {session.unresolved === 1 ? 'write' : 'writes'}
          </span>
        )}
        {session.error && <span className="max-w-64 text-rose-light">{session.error}</span>}
      </div>
    )
  }
  return (
    <div className="flex flex-wrap items-center gap-2 text-xs">
      <button
        type="button"
        disabled={session.busy}
        onClick={() => void session.create()}
        className="rounded-md bg-gold px-2 py-1 font-semibold text-teal disabled:opacity-40"
      >
        Create identity
      </button>
      {hasLocalKeyProvider() && (
        <button
          type="button"
          disabled={session.busy}
          onClick={() => void session.unlock()}
          className="rounded-md border border-cream/40 px-2 py-1 text-cream disabled:opacity-40"
        >
          Unlock saved key
        </button>
      )}
      {session.error && <span className="max-w-64 text-rose-light">{session.error}</span>}
    </div>
  )
}

function message(reason: unknown) {
  return reason instanceof Error ? reason.message : String(reason)
}

function fingerprint(identity: SignedIdentity) {
  return b64url(identity.provider.publicKey).slice(0, 12)
}
