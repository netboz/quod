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
  readEntityEidolons, readEidolonWorkspace, singleBinding, GoalFailure } from '../../client/src/world.js'
import type { EidolonChoice, EidolonWorkspace, MenuEntry, ProofView, Subject, WorldMark } from '../../client/src/world.js'
import type { WorldScene } from '../../client/src/world-scene.js'
import { connectSimulation, readSimulationWorld } from '../../client/src/simulation.js'

export default function World() {
  const { identity, agent, busy, unresolved, finishSetup, error: sessionError } = useSignedSession()
  const canvas = useRef<HTMLCanvasElement>(null)
  const [scene, setScene] = useState<WorldScene | null>(null)
  const [immersive, setImmersive] = useState(false)
  const [navigationActive, setNavigationActive] = useState(false)
  const [vr, setVr] = useState({ available: false, reason: 'Checking VR availability…' })
  const [enteringVR, setEnteringVR] = useState(false)
  const [openingTool, setOpeningTool] = useState(false)
  const [toolError, setToolError] = useState<string | null>(null)
  const [inspectionRevision, setInspectionRevision] = useState(0)
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
  const [menu, setMenu] = useState<{ subject: Subject; entries: MenuEntry[]; error?: string } | null>(null)
  const [eidolons, setEidolons] = useState<{ subject: Subject; choices: EidolonChoice[]; error?: string; accessDenied?: boolean } | null>(null)
  const [workspace, setWorkspace] = useState<
    { kind: 'proof'; key: string; view: ProofView } | { kind: 'code'; key: string; code: EidolonWorkspace } | null>(null)
  const [focused, setFocused] = useState(false)
  const pick = useRef(setSelected)
  pick.current = setSelected
  // Async view reads are invalidated when the acting identity or target changes.
  const projection = useRef({ identity, agent, view })
  const context = useRef({ identity, agent, selected, view, mode, revision })
  context.current = { identity, agent, selected, view, mode, revision }
  const currentRequest = (request: typeof context.current) =>
    Object.entries(request).every(([key, value]) => context.current[key as keyof typeof request] === value)

  const licenceUnavailable = !identity ? 'Sign in to check licence lens availability.'
    : licenceCheck?.identity !== identity ? 'Checking licence lens availability…'
    : licenceCheck.reason
  const viewUnavailable = view === 'licence' ? licenceUnavailable : null

  useEffect(() => {
    const xr = (navigator as Navigator & { xr?: EventTarget & {
      isSessionSupported(mode: string): Promise<boolean>
    } }).xr
    let version = 0
    const check = async () => {
      const request = ++version
      setVr({ available: false, reason: 'Checking VR availability…' })
      try {
        const available = Boolean(xr && await xr.isSessionSupported('immersive-vr'))
        if (request === version) setVr({ available, reason: available
          ? 'Requires a connected VR headset.' : 'VR is unavailable in this browser or device.' })
      } catch {
        if (request === version) setVr({ available: false, reason: 'The browser could not check VR availability.' })
      }
    }
    void check()
    xr?.addEventListener('devicechange', check)
    return () => { version++; xr?.removeEventListener('devicechange', check) }
  }, [revision])

  useEffect(() => { setToolError(null); setOpeningTool(false) }, [identity, agent, selected, view, mode, revision])

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
    if (view !== 'physics' || !scene || !identity || !agent) return
    scene.simulation(null)
    let active = true
    let stream: ReturnType<typeof connectSimulation> | undefined
    void readSimulationWorld(identity, agent).then(world => {
      if (!active) return
      stream = connectSimulation(identity, agent, {
        projection(current) {
          scene.simulation(current)
          setMarks(current.marks)
          setStatus('Live simulation. VR: left grip + pad for travel; left pad click for turn or teleport; right pad for actions.')
        },
        frame(current) { scene.simulation(current) },
        refreshing() {
          scene.simulation(null); setStatus('World updating. Movement paused…')
          setRevision(value => value + 1)
          return false
        },
        unavailable(reason) { scene.simulation(null); setStatus(reason) },
      }, { world })
    }).catch(error => { if (active) setStatus(String(error)) })
    const online = () => setRevision(value => value + 1)
    window.addEventListener('online', online)
    return () => {
      window.removeEventListener('online', online)
      active = false
      stream?.close()
      scene.simulation(undefined)
    }
  }, [view, scene, identity, agent, revision])

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
    if (view === 'physics') return
    const load = async () => {
      try {
        if (view === 'lobby') {
          const result = await readPersonalLobby(identity, agent, mode)
          if (!active) return
          setMarks(result?.marks ?? [])
          setModes(result?.modes ?? [])
          setMissingLobby(result === null)
          setStatus(result
            ? 'Your lobby is ready.'
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
      }).catch(error => { if (active) { setMenu({ subject, entries: [], error: String(error) }) } })
      void readEntityEidolons(identity, agent, subject).then(choices => {
        if (active) setEidolons({ subject, choices })
      }).catch(error => {
        if (active) setEidolons({ subject, choices: [], error: String(error),
          accessDenied: error instanceof GoalFailure && error.accessDenied })
      })
    }
    return () => { active = false }
  }, [identity, agent, selected, inspectionRevision])

  const openWorkspace = async (entry?: MenuEntry, subject = selected) => {
    if (!identity || !agent || !subject?.anchor || openingTool) return
    const request = context.current
    setOpeningTool(true)
    setToolError(null)
    try {
      // The shortcut locates the existing occurrence; its authored menu still
      // supplies the action and the anchored signed read supplies the form.
      const action = entry ?? (await readDeviceMenu(identity, agent, subject))
        .find(candidate => candidate.view === 'proof_console')
      if (!currentRequest(request)) return
      if (!action) throw new Error('This object does not offer a Prolog console.')
      const key = `${subject.ontology}:${[...subject.anchor]}:${renderTerm(subject.entity)}:${action.view}`
      if (workspace?.key === key) { setFocused(true); return }
      const goal = anchoredGoal({ namespace: subject.ontology, anchor: subject.anchor },
        compound('lobby_workspace', [subject.entity, atom(action.view), variable('View')]))
      const reply = await signedGoal(identity, { mode: 'read', agent, goal })
      const form = proofForm(readGuiView(singleBinding(reply, 'View')))
      if (!currentRequest(request)) return
      setWorkspace({ kind: 'proof', key, view: form })
      setFocused(true)
    } catch (error) {
      if (currentRequest(request)) setToolError(`Could not open the console: ${String(error)}`)
    } finally {
      if (currentRequest(request)) setOpeningTool(false)
    }
  }

  const openEidolon = async (choice: EidolonChoice) => {
    if (!identity || !agent || !selected?.anchor || openingTool) return
    const request = context.current
    const key = `${selected.ontology}:${[...selected.anchor]}:${renderTerm(selected.entity)}:${choice.recipe.name}`
    if (workspace?.key === key) { setFocused(true); return }
    setOpeningTool(true)
    setToolError(null)
    try {
      const code = await readEidolonWorkspace(identity, agent, selected, choice)
      codeForm(code.view)
      if (!currentRequest(request)) return
      setWorkspace({ kind: 'code', key, code })
      setFocused(true)
    } catch (error) {
      if (currentRequest(request)) setToolError(`Could not open the source view: ${String(error)}`)
    } finally {
      if (currentRequest(request)) setOpeningTool(false)
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
  const consoleSubject = devices.find(mark => mark.id === 'console')?.depicts
  const sourceChoices = eidolons?.subject === selected
    ? eidolons.choices.filter(choice => choice.purpose === 'prolog' && choice.style === 'source') : []
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
        {view === 'lobby'
          ? <button className="world-primary" disabled={!consoleSubject || openingTool}
              onClick={() => void openWorkspace(undefined, consoleSubject)}>
              {openingTool ? 'Opening…' : 'Open console'}</button>
          : <button className="world-primary" onClick={() => setView('lobby')}>Return to lobby</button>}
        <button disabled={!scene || !vr.available || enteringVR || immersive} aria-describedby="vr-availability" onClick={() => {
          setEnteringVR(true)
          void scene?.immersive().catch(error => setVr({ available: true, reason: `VR could not start: ${String(error)}` }))
            .finally(() => setEnteringVR(false))
        }}>{enteringVR ? 'Starting VR…' : immersive ? 'VR active' : 'Enter VR'}</button>
        {missingLobby && selectedAccount &&
          <button disabled={busy || unresolved > 0} onClick={() => void finishSetup()}>Finish account setup</button>}
      </div>
      <p id="vr-availability" className="world-help">{sceneError ? 'VR requires a working 3D view.' : vr.reason}</p>
      {view === 'lobby' && !consoleSubject && <p>The console is unavailable until its lobby view loads.</p>}
      {toolError && <p role="alert">{toolError}</p>}
      {selected && selected.kind !== 'ontology' && (selectedMenu === null || menu?.error || Boolean(selectedMenu.length)) &&
        <div className="world-menu" aria-label="Selected object actions">
          <p>{renderTerm(selected.entity)}</p>
          {menu?.subject === selected && menu.error ? <p role="alert">Actions could not be loaded: {menu.error}</p>
            : selectedMenu === null ? <p>Loading object actions…</p> : selectedMenu.map(entry =>
              <button key={entry.id} disabled={openingTool} onClick={() => void openWorkspace(entry)}>{entry.label}</button>)}
          <button onClick={() => setSelected(null)}>Dismiss selection</button>
        </div>}
      <details className="world-advanced">
        <summary>Advanced</summary>
        <div className="world-controls">
          <label>Scene <select aria-label="Scene" value={view} onChange={event => setView(event.target.value)}>
            <option value="lobby">Personal lobby</option>
            <option value="physics">Simulation</option>
            <option value="licence" disabled={licenceUnavailable !== null}>Software licences</option>
          </select></label>
          {view === 'lobby' && <label>Appearance <select aria-label="Appearance" value={mode} onChange={event => setMode(event.target.value)}>
            {modes.map(purpose => <option key={purpose} value={purpose}>
              {purpose === 'playing' ? 'Normal' : purpose === 'edition' ? 'Structure' : purpose}
            </option>)}
          </select></label>}
          <button onClick={() => setRevision(n => n + 1)} disabled={!identity || !agent}>Reload scene</button>
        </div>
        <p className="world-help">Structure changes the visual representation; it does not enable world editing.</p>
        {licenceUnavailable && <p>Software licences: {licenceUnavailable}</p>}
        <h2>Inspect objects and Prolog knowledge</h2>
        <p>Choose a target to see its offered source tools. Access depends on your permissions.</p>
        <label>Inspect <select aria-label="Inspect" value="" onChange={event => {
          const value = event.target.value
          if (value.startsWith('object:')) setSelected(devices[Number(value.slice(7))]?.depicts ?? null)
          else {
            const ref = ontologies.get(value)
            if (ref) setSelected({ kind: 'ontology', ontology: ref.namespace, anchor: fromB64url(ref.anchor), entity: atom('ontology') })
          }
        }}>
          <option value="" disabled>Choose an object or knowledge base</option>
          <optgroup label="Scene objects">
            {devices.map((device, index) => <option key={device.id} value={`object:${index}`}>{device.id}</option>)}
          </optgroup>
          <optgroup label="Prolog knowledge bases">
            {[...ontologies.entries()].map(([key, ref]) => <option key={key} value={key}>{ref.namespace}</option>)}
          </optgroup>
        </select></label>
        {selected && <div className="world-inspector" aria-label="Inspection tools">
          <p className="world-target">{selected.ontology} · {renderTerm(selected.entity)}</p>
          {eidolons?.subject !== selected ? <p>Loading source tools…</p>
            : eidolons.accessDenied ? <p>Source inspection is restricted for this target. Your current account does not have access.</p>
            : eidolons.error ? <>
              <p role="alert">Source tools could not be loaded: {eidolons.error}</p>
              <button onClick={() => setInspectionRevision(value => value + 1)}>Retry inspection</button>
            </> : sourceChoices.length === 0 ? <p>No supported source tool is offered for this target.</p>
              : sourceChoices.map((choice, index) => <button key={index} disabled={openingTool}
                  onClick={() => void openEidolon(choice)}>
                  View Prolog source{sourceChoices.length > 1 ? ` (${choice.recipe.namespace})` : ''}
                </button>)}
          <button onClick={() => setSelected(null)}>Clear inspection</button>
        </div>}
      </details>
    </section>
    {workspace && <section className="world-workspace" hidden={!focused || immersive} aria-label="Focused console">
      {workspace.kind === 'proof'
        ? <ConsoleWorkspace view={workspace.view} onClose={() => setFocused(false)} scene={scene} visible={focused} />
        : <PrologEditor workspace={workspace.code} onClose={() => setFocused(false)} scene={scene} visible={focused} />}
    </section>}
  </div>
}
