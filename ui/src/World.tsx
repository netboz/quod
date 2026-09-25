import { useEffect, useRef, useState } from 'react'
import { SessionControls } from './Session'
import { useSignedSession } from './session-context'
import { ConsoleWorkspace } from './Console'
import { compound, renderTerm, variable } from '../../client/src/prolog-term.js'
import { signedGoal, readSystemOntologies } from '../../client/src/signed-client.js'
import type { SignedIdentity } from '../../client/src/signed-client.js'
import { readLensView } from '../../client/src/lens.js'
import { anchoredGoal, readPersonalLobby, readDeviceMenu, readProofView, singleBinding } from '../../client/src/world.js'
import type { MenuEntry, ProofView, Subject, WorldMark } from '../../client/src/world.js'
import type { WorldScene } from '../../client/src/world-scene.js'

export default function World() {
  const { identity, agent, error: sessionError } = useSignedSession()
  const canvas = useRef<HTMLCanvasElement>(null)
  const [scene, setScene] = useState<WorldScene | null>(null)
  const [sceneError, setSceneError] = useState<string | null>(null)
  const [marks, setMarks] = useState<WorldMark[]>([])
  const [status, setStatus] = useState('Sign in and select an agent to open its lobby.')
  const [view, setView] = useState('lobby')
  const [mode, setMode] = useState('playing')
  const [revision, setRevision] = useState(0)
  const [licenceCheck, setLicenceCheck] = useState<{ identity: SignedIdentity; reason: string | null } | null>(null)
  const [selected, setSelected] = useState<Subject | null>(null)
  const [menu, setMenu] = useState<MenuEntry[] | null>(null)
  const [workspace, setWorkspace] = useState<{ key: string; view: ProofView } | null>(null)
  const [focused, setFocused] = useState(false)
  const pick = useRef(setSelected)
  pick.current = setSelected
  // Async view reads are invalidated when the acting identity or target changes.
  const context = useRef({ identity, agent, selected })
  context.current = { identity, agent, selected }

  const licenceUnavailable = !identity ? 'Sign in to check licence lens availability.'
    : licenceCheck?.identity !== identity ? 'Checking licence lens availability…'
    : licenceCheck.reason
  const viewUnavailable = view === 'licence' ? licenceUnavailable : null

  useEffect(() => {
    let active = true
    setLicenceCheck(null)
    if (identity) {
      void readSystemOntologies(identity).then(ontologies => {
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
        world = createWorld(canvas.current, subject => pick.current(subject))
        setScene(world)
      } catch (error) { setSceneError(String(error)) }
    }).catch(error => { if (active) setSceneError(String(error)) })
    return () => { active = false; world?.dispose() }
  }, [])

  useEffect(() => { scene?.paint(marks) }, [scene, marks])

  useEffect(() => {
    let active = true
    setSelected(null)
    setMenu(null)
    setMarks([])
    setWorkspace(null)
    setFocused(false)
    if (!identity || !agent) {
      setStatus('Sign in and select an agent to open its lobby.')
      return
    }
    if (viewUnavailable !== null) {
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
      } catch (error) { if (active) setStatus(`Could not open this view: ${String(error)}`) }
    }
    void load()
    return () => { active = false }
  }, [identity, agent, view, mode, revision, viewUnavailable])

  useEffect(() => {
    let active = true
    setMenu(null)
    if (identity && agent && selected) {
      void readDeviceMenu(identity, agent, selected).then(entries => {
        if (active) setMenu(entries)
      }).catch(error => { if (active) { setMenu([]); setStatus(`Could not read the actions: ${String(error)}`) } })
    }
    return () => { active = false }
  }, [identity, agent, selected])

  const openWorkspace = async () => {
    if (!identity || !agent || !selected?.anchor) return
    const requestContext = context.current
    const key = `${selected.ontology}:${[...selected.anchor]}:${renderTerm(selected.entity)}`
    if (workspace?.key === key) { setFocused(true); return }
    try {
      const goal = anchoredGoal({ namespace: selected.ontology, anchor: selected.anchor },
        compound('lobby_workspace', [selected.entity, variable('View')]))
      const reply = await signedGoal(identity, { mode: 'read', agent, goal })
      const form = readProofView(singleBinding(reply, 'View'))
      const current = context.current
      if (current.identity !== requestContext.identity || current.agent !== requestContext.agent ||
          current.selected !== requestContext.selected) return
      setWorkspace({ key, view: form })
      setFocused(true)
    } catch (error) {
      const current = context.current
      if (current.identity === requestContext.identity && current.agent === requestContext.agent &&
          current.selected === requestContext.selected) setStatus(`Could not open the console: ${String(error)}`)
    }
  }

  const devices = marks.filter(mark => mark.depicts?.anchor)
  return <div className="world-shell">
    <canvas ref={canvas} className="world-canvas" aria-label="Personal lobby" />
    <header className="world-header">
      <a href="/" className="world-brand">quod <span>∴</span></a>
      <SessionControls />
      <a href="/explorer/">Explorer ↗</a>
    </header>
    <section className="world-panel" aria-label="World controls">
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
        {view === 'lobby' && <label>Presentation <select aria-label="Presentation" value={mode} onChange={event => setMode(event.target.value)}>
          <option value="playing">Playing</option><option value="edition">Structure</option>
        </select></label>}
        <button onClick={() => setRevision(n => n + 1)} disabled={!identity || !agent}>Refresh view</button>
        <button disabled={!scene} onClick={() => {
          void scene?.immersive().catch(error => setStatus(`Immersive mode unavailable: ${String(error)}`))
        }}>Enter VR</button>
      </div>
      {licenceUnavailable && <p>{licenceUnavailable}</p>}
      {devices.length > 0 && <div className="world-devices" aria-label="Devices">
        {devices.map(device => <button key={device.id} onClick={() => setSelected(device.depicts)}>{device.id}</button>)}
      </div>}
      {selected && <div className="world-menu" aria-label="Device actions">
        {menu === null ? <p>Reading actions…</p> : menu.length === 0 ? <p>No available actions.</p> : menu.map(entry =>
          <button key={entry.id} onClick={() => void openWorkspace()}>{entry.label}</button>)}
        <button onClick={() => setSelected(null)}>Dismiss</button>
      </div>}
    </section>
    {workspace && <section className="world-workspace" hidden={!focused} aria-label="Focused console">
      <ConsoleWorkspace view={workspace.view} onClose={() => setFocused(false)} />
    </section>}
  </div>
}
