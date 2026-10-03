import { useEffect, useRef, useState } from 'react'
import { SessionControls } from './Session'
import { fromB64url, b64url } from '../../client/src/key-provider.js'
import { accountReference } from '../../client/src/accounts.js'
import { useSignedSession } from './session-context'
import { ConsoleWorkspace } from './Console'
import { PrologEditor } from './PrologEditor'
import { atom, compound, renderTerm, variable } from '../../client/src/prolog-term.js'
import { signedGoal, readSystemOntologies } from '../../client/src/signed-client.js'
import type { SignedIdentity } from '../../client/src/signed-client.js'
import { readLensView } from '../../client/src/lens.js'
import { anchoredGoal, readPersonalLobby, readDeviceMenu, readGuiView, proofForm, codeForm,
  readEntityEidolons, readEidolonWorkspace, singleBinding } from '../../client/src/world.js'
import type { EidolonChoice, EidolonWorkspace, MenuEntry, ProofView, Subject, WorldMark } from '../../client/src/world.js'
import type { WorldScene } from '../../client/src/world-scene.js'

export default function World() {
  const { identity, agent, busy, unresolved, finishSetup, error: sessionError } = useSignedSession()
  const canvas = useRef<HTMLCanvasElement>(null)
  const [scene, setScene] = useState<WorldScene | null>(null)
  const [immersive, setImmersive] = useState(false)
  const [navigationActive, setNavigationActive] = useState(false)
  const [sceneError, setSceneError] = useState<string | null>(null)
  const [marks, setMarks] = useState<WorldMark[]>([])
  const [status, setStatus] = useState('Sign in and select an agent to open its lobby.')
  const [view, setView] = useState('lobby')
  const [missingLobby, setMissingLobby] = useState(false)
  const [mode, setMode] = useState('playing')
  const [modes, setModes] = useState<string[]>([])
  const [catalogue, setCatalogue] = useState<{ namespace: string; anchor: string }[]>([])
  const [revision, setRevision] = useState(0)
  const [licenceCheck, setLicenceCheck] = useState<{ identity: SignedIdentity; reason: string | null } | null>(null)
  const [selected, setSelected] = useState<Subject | null>(null)
  const [menu, setMenu] = useState<{ subject: Subject; entries: MenuEntry[] } | null>(null)
  const [eidolons, setEidolons] = useState<{ subject: Subject; choices: EidolonChoice[] } | null>(null)
  const [workspace, setWorkspace] = useState<
    { kind: 'proof'; key: string; view: ProofView } | { kind: 'code'; key: string; code: EidolonWorkspace } | null>(null)
  const [focused, setFocused] = useState(false)
  const pick = useRef(setSelected)
  pick.current = setSelected
  // Async view reads are invalidated when the acting identity or target changes.
  const projection = useRef({ identity, agent, view })
  const context = useRef({ identity, agent, selected })
  context.current = { identity, agent, selected }

  const licenceUnavailable = !identity ? 'Sign in to check licence lens availability.'
    : licenceCheck?.identity !== identity ? 'Checking licence lens availability…'
    : licenceCheck.reason
  const viewUnavailable = view === 'licence' ? licenceUnavailable : null

  useEffect(() => {
    let active = true
    setLicenceCheck(null)
    setCatalogue([])
    if (identity) {
      void readSystemOntologies(identity).then(ontologies => {
        if (active) setCatalogue(ontologies)
        // This menu entry opens the authored licence lens over licence data.
        const installed = ['quod:lens', 'quod:licence'].every(namespace =>
          ontologies.some(ontology => ontology.namespace === namespace))
        if (active) setLicenceCheck({ identity, reason: installed ? null
          : 'Licence lens unavailable: this network has not registered its lens and licence ontologies.' })
      }).catch(error => {
        if (active) setLicenceCheck({ identity, reason: `Could not check licence lens availability: ${String(error)}` })
      })
    }
    return () => { active = false }
  }, [identity, revision])

  useEffect(() => {
    let active = true
    let world: WorldScene | null = null
    void import('../../client/src/world-scene.js').then(({ createWorld }) => {
      if (!active || !canvas.current) return
      try {
        world = createWorld(canvas.current, subject => pick.current(subject), setImmersive,
          error => { if (active) setStatus(error.message) },
          captured => { if (active) setNavigationActive(captured) })
        setScene(world)
      } catch (error) { setSceneError(String(error)) }
    }).catch(error => { if (active) setSceneError(String(error)) })
    return () => { active = false; world?.dispose() }
  }, [])

  useEffect(() => { scene?.paint(marks) }, [scene, marks])

  useEffect(() => {
    let active = true
    const previous = projection.current
    const sameScope = previous.identity === identity && previous.agent === agent && previous.view === view
    projection.current = { identity, agent, view }
    if (!sameScope) {
      setMarks([])
      setWorkspace(null)
      setFocused(false)
    }
    setSelected(null)
    setMenu(null)
    setMissingLobby(false)
    if (!identity || !agent) {
      setMarks([])
      setStatus('Sign in and select an agent to open its lobby.')
      return
    }
    if (viewUnavailable !== null) {
      setMarks([])
      setStatus(viewUnavailable)
      return
    }
    setStatus('Reading the ontology…')
    const load = async () => {
      try {
        if (view === 'lobby') {
          const result = await readPersonalLobby(identity, agent, mode)
          if (!active) return
          setMarks(result?.marks ?? [])
          setModes(result?.modes ?? [])
          setMissingLobby(result === null)
          setStatus(result
            ? 'Your personal lobby. Select the console to see its actions.'
            : 'This agent has no personal lobby yet.')
        } else {
          const result = await readLensView(identity, agent, 'work_licences', ['quod'])
          if (!active) return
          setMarks(result.marks ?? [])
          setStatus(result.marks ? 'Licence lens · Quod release dependencies.'
            : 'The licence lens has no compatible representation for this data.')
        }
      } catch (error) {
        if (active) { setMarks([]); setStatus(`Could not open this view: ${String(error)}`) }
      }
    }
    void load()
    return () => { active = false }
  }, [identity, agent, view, mode, revision, viewUnavailable])

  useEffect(() => {
    let active = true
    setMenu(null)
    setEidolons(null)
    if (identity && agent && selected) {
      const subject = selected
      if (subject.kind === 'ontology') setMenu({ subject, entries: [] })
      else void readDeviceMenu(identity, agent, subject).then(entries => {
        if (active) setMenu({ subject, entries })
      }).catch(error => { if (active) { setMenu({ subject, entries: [] }); setStatus(`Could not read the actions: ${String(error)}`) } })
      void readEntityEidolons(identity, agent, subject).then(choices => {
        if (active) setEidolons({ subject, choices })
      }).catch(error => { if (active) { setEidolons({ subject, choices: [] }); setStatus(`Could not read the eidolons: ${String(error)}`) } })
    }
    return () => { active = false }
  }, [identity, agent, selected])

  const openWorkspace = async (entry: MenuEntry) => {
    if (!identity || !agent || !selected?.anchor) return
    const requestContext = context.current
    const key = `${selected.ontology}:${[...selected.anchor]}:${renderTerm(selected.entity)}:${entry.view}`
    if (workspace?.key === key) {
      setFocused(true)
      return
    }
    try {
      const goal = anchoredGoal({ namespace: selected.ontology, anchor: selected.anchor },
        compound('lobby_workspace', [selected.entity, atom(entry.view), variable('View')]))
      const reply = await signedGoal(identity, { mode: 'read', agent, goal })
      const form = proofForm(readGuiView(singleBinding(reply, 'View')))
      const current = context.current
      if (current.identity !== requestContext.identity || current.agent !== requestContext.agent ||
          current.selected !== requestContext.selected) return
      setWorkspace({ kind: 'proof', key, view: form })
      setFocused(true)
    } catch (error) {
      const current = context.current
      if (current.identity === requestContext.identity && current.agent === requestContext.agent &&
          current.selected === requestContext.selected) setStatus(`Could not open the console: ${String(error)}`)
    }
  }

  const openEidolon = async (choice: EidolonChoice) => {
    if (!identity || !agent || !selected?.anchor) return
    const requestContext = context.current
    const key = `${selected.ontology}:${[...selected.anchor]}:${renderTerm(selected.entity)}:${choice.recipe.name}`
    if (workspace?.key === key) { setFocused(true); return }
    try {
      const code = await readEidolonWorkspace(identity, agent, selected, choice)
      codeForm(code.view) // Refuse an unsupported semantic form before replacing the open draft.
      const current = context.current
      if (current.identity !== requestContext.identity || current.agent !== requestContext.agent ||
          current.selected !== requestContext.selected) return
      setWorkspace({ kind: 'code', key, code })
      setFocused(true)
    } catch (error) {
      const current = context.current
      if (current.identity === requestContext.identity && current.agent === requestContext.agent &&
          current.selected === requestContext.selected) setStatus(`Could not open this eidolon: ${String(error)}`)
    }
  }

  const selectedMenu = menu?.subject === selected ? menu.entries : null
  const activate = useRef<(entry: MenuEntry) => void>(() => {})
  activate.current = entry => { void openWorkspace(entry) }
  useEffect(() => {
    scene?.setActionMenu(selectedMenu ?? [], entry => activate.current(entry))
    return () => scene?.setActionMenu([], entry => activate.current(entry))
  }, [scene, selected, selectedMenu])

  const account = identity ? accountReference(identity) : null
  const selectedAccount = account && account.namespace === agent?.namespace &&
    account.anchor === agent?.anchor && account.instanceText === agent?.instanceText
  const devices = marks.filter(mark => mark.depicts?.anchor)
  const ontologies = new Map(catalogue.map(ref => [ref.namespace + ':' + ref.anchor, ref]))
  if (agent) {
    const ref = { namespace: agent.namespace, anchor: typeof agent.anchor === 'string' ? agent.anchor : b64url(agent.anchor) }
    ontologies.set(ref.namespace + ':' + ref.anchor, ref)
  }
  for (const { depicts } of devices) if (depicts?.anchor) {
    const ref = { namespace: depicts.ontology, anchor: b64url(depicts.anchor) }
    ontologies.set(ref.namespace + ':' + ref.anchor, ref)
  }
  return <div className="world-shell">
    <canvas ref={canvas} className="world-canvas" aria-label="Personal lobby" tabIndex={0} />
    {navigationActive && <div className="world-crosshair" aria-hidden="true" />}
    <div className={`world-navigation-hint${navigationActive ? ' active' : ''}`} aria-live="polite">
      {navigationActive ? 'Mouse to look · ZQSD, WASD or arrows to move · Shift for faster movement · Esc to release'
        : 'Click the world to explore · ZQSD, WASD or arrows to move · Shift for faster movement'}
    </div>
    <header className={`world-header${navigationActive ? ' navigation-active' : ''}`}>
      <a href="/" className="world-brand">quod <span>∴</span></a>
      <SessionControls />
      <a href="/explorer/">Explorer ↗</a>
    </header>
    <section className={`world-panel${navigationActive ? ' navigation-active' : ''}`} aria-label="World controls">
      <p className="world-eyebrow">YOUR SPACE</p>
      <h1>Personal lobby</h1>
      <p role="status">{sessionError ?? status}</p>
      {sceneError && <>
        <p>The 3D view could not start, so Enter VR is unavailable. You can still open the console below.</p>
        <details>
          <summary>3D startup error</summary>
          <p>{sceneError}</p>
        </details>
      </>}
      <div className="world-controls">
        <label>View <select aria-label="View" value={view} onChange={event => setView(event.target.value)}>
          <option value="lobby">Personal lobby</option>
          <option value="licence" disabled={licenceUnavailable !== null}>
            Licence lens{licenceUnavailable !== null ? ' — unavailable' : ''}
          </option>
        </select></label>
        {view === 'lobby' && <label>Eidolon <select aria-label="Eidolon" value={mode} onChange={event => setMode(event.target.value)}>
          {modes.map(purpose => <option key={purpose} value={purpose}>{purpose}</option>)}
        </select></label>}
        <button onClick={() => setRevision(n => n + 1)} disabled={!identity || !agent}>Refresh view</button>
        {missingLobby && selectedAccount &&
          <button disabled={busy || unresolved > 0} onClick={() => void finishSetup()}>Finish account setup</button>}
        <button disabled={!scene || immersive} onClick={() => scene?.captureNavigation()}>Explore in 3D</button>
        <button disabled={!scene} onClick={() => {
          void scene?.immersive().catch(error => setStatus(`Immersive mode unavailable: ${String(error)}`))
        }}>Enter VR</button>
      </div>
      {licenceUnavailable && <p>{licenceUnavailable}</p>}
      {devices.length > 0 && <div className="world-devices" aria-label="Devices">
        {devices.map(device => <button key={device.id} onClick={() => setSelected(device.depicts)}>{device.id}</button>)}
      </div>}
      {identity && agent && <label>Ontology browser <select aria-label="Ontology browser" value="" onChange={event => {
        const ref = ontologies.get(event.target.value)
        if (ref) setSelected({ kind: 'ontology', ontology: ref.namespace, anchor: fromB64url(ref.anchor), entity: atom('ontology') })
      }}>
        <option value="" disabled>Choose an ontology</option>
        {[...ontologies.entries()].map(([key, ref]) => <option key={key} value={key}>{ref.namespace}</option>)}
      </select></label>}
      {selected && <div className="world-menu" aria-label="Selected target">
        <p>{selected.ontology} · {renderTerm(selected.entity)}</p>
        {eidolons?.subject === selected && eidolons.choices.length > 0 && <label>Eidolon <select
          aria-label="Selected entity eidolon" value="" onChange={event => {
            const choice = eidolons.choices[Number(event.target.value)]
            if (choice) void openEidolon(choice)
          }}>
          <option value="" disabled>Choose an eidolon</option>
          {eidolons.choices.map((choice, index) => <option key={index} value={index}>{choice.purpose} · {choice.style}</option>)}
        </select></label>}
        {selectedMenu === null ? <p>Reading actions…</p> : selectedMenu.length === 0 ? <p>No available actions.</p> : selectedMenu.map(entry =>
          <button key={entry.id} onClick={() => void openWorkspace(entry)}>{entry.label}</button>)}
        <button onClick={() => setSelected(null)}>Dismiss</button>
      </div>}
    </section>
    {workspace && <section className="world-workspace" hidden={!focused || immersive} aria-label="Focused console">
      {workspace.kind === 'proof'
        ? <ConsoleWorkspace view={workspace.view} onClose={() => setFocused(false)} scene={scene} visible={focused} />
        : <PrologEditor workspace={workspace.code} onClose={() => setFocused(false)} scene={scene} visible={focused} />}
    </section>}
  </div>
}
