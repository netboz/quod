import { useEffect, useMemo, useRef, useState } from 'react'
import { SessionControls } from './Session'
import { fromB64url, b64url } from '../../client/src/key-provider.js'
import { accountReference } from '../../client/src/accounts.js'
import { useSignedSession } from './session-context'
import { ConsoleWorkspace } from './Console'
import { PrologEditor } from './PrologEditor'
import { OntologyInspection } from './OntologyInspection'
import { compound, renderTerm, variable } from '../../client/src/prolog-term.js'
import { signedGoal, readSystemOntologies } from '../../client/src/signed-client.js'
import type { SignedIdentity } from '../../client/src/signed-client.js'
import { readLensView } from '../../client/src/lens.js'
import { anchoredGoal, readSpaceNavigation, readGuiView, proofForm, codeForm,
  readEntityEidolons, readEidolon, ontologySubject, singleBinding, GoalFailure } from '../../client/src/world.js'
import type { EidolonChoice, EidolonWorkspace, EidolonRepresentation, MenuEntry, ProofView, Subject, WorldMark } from '../../client/src/world.js'
import type { WorldScene, XRState } from '../../client/src/world-scene.js'
import { GuiQuestion, GuiQuestionList } from './GuiQuestion'
import { connectGuiHud } from '../../client/src/gui-view.js'
import { questionController, questionKey } from '../../client/src/question-controller.js'
import type { QuestionController } from '../../client/src/question-controller.js'
import type { GuiQuestionReference } from '../../client/src/world.js'
import { GuiWorkspace } from './GuiWorkspace'
import { operationController } from '../../client/src/operation-controller.js'
import { operationSubject } from '../../client/src/gui-operation.js'
import type { OperationController } from '../../client/src/operation-controller.js'
import { spaceLibraryController } from '../../client/src/space-library.js'
import type { SpaceLibraryController } from '../../client/src/space-library.js'
import { spaceKey } from '../../client/src/space-entry.js'
import type { SpaceReference } from '../../client/src/world.js'
import { readTerm } from '../../client/src/prolog-read.js'
import { connectControllerView } from '../../client/src/controller-view.js'
import { controllerPanel } from '../../client/src/controller-panel.js'
import { connectWorldView } from '../../client/src/simulation.js'

export default function World() {
  const { identity, agent, busy, unresolved, finishSetup, error: sessionError } = useSignedSession()
  const account = identity ? accountReference(identity) : null
  const [controllerRevision, setControllerRevision] = useState(0)
  const canvas = useRef<HTMLCanvasElement>(null)
  const [scene, setScene] = useState<WorldScene | null>(null)
  const [immersive, setImmersive] = useState(false)
  const [navigationActive, setNavigationActive] = useState(false)
  const [movementHint, setMovementHint] = useState('')
  const [vr, setVr] = useState({ available: false, reason: 'Checking VR availability…' })
  const [xrState, setXRState] = useState<XRState>('preparing')
  const [xrError, setXRError] = useState<string | null>(null)
  const [openingTool, setOpeningTool] = useState(false)
  const [toolError, setToolError] = useState<string | null>(null)
  const [inspectionRevision, setInspectionRevision] = useState(0)
  const [sceneError, setSceneError] = useState<string | null>(null)
  const [marks, setMarks] = useState<WorldMark[]>([])
  const [status, setStatus] = useState('Sign in and select an agent to open its lobby.')
  const [view, setView] = useState('lobby')
  const actorKey = JSON.stringify([identity && b64url(identity.networkId),
    identity && b64url(identity.provider.publicKey), agent?.namespace,
    agent?.anchor instanceof Uint8Array ? b64url(agent.anchor) : agent?.anchor, agent?.instanceText])
  const [destination, setDestination] = useState<{ reference: SpaceReference; label: string; actor: string } | null>(null)
  const space = destination?.actor === actorKey ? destination : null
  const spaceIdentity = space ? spaceKey(space.reference) : null
  const retireView = useRef<() => void>(() => {})
  const library = useRef<SpaceLibraryController | null>(null)
  useEffect(() => () => { library.current?.close(); library.current = null }, [identity, agent, view, spaceIdentity])
  const retireSpace = () => {
    retireView.current(); scene?.releaseNavigation()
    library.current?.close(); library.current = null
  }
  const navigate = (reference: SpaceReference | null, label = '') => {
    library.current?.close(); library.current = null
    setFocused(false)
    if (view === 'lobby' && (reference ? spaceKey(reference) : null) === spaceIdentity) return
    retireSpace()
    setDestination(reference ? { reference, label, actor: actorKey } : null)
    setView('lobby')
  }
  const [missingLobby, setMissingLobby] = useState(false)
  const [mode, setMode] = useState('playing')
  const [modes, setModes] = useState<string[]>([])
  const [catalogue, setCatalogue] = useState<{ namespace: string; anchor: string }[]>([])
  const [revision, setRevision] = useState(0)
  const [licenceCheck, setLicenceCheck] = useState<{ identity: SignedIdentity; reason: string | null } | null>(null)
  const [selected, setSelected] = useState<Subject | null>(null)
  const [eidolons, setEidolons] = useState<{ subject: Subject; choices: EidolonChoice[]; error?: string; accessDenied?: boolean } | null>(null)
  const [workspace, setWorkspace] = useState<
    { kind: 'controllers'; key: string; controller: ReturnType<typeof controllerPanel> } | { kind: 'operation'; key: string; controller: OperationController } | { kind: 'library'; key: string; controller: SpaceLibraryController } | { kind: 'proof'; key: string; view: ProofView } | { kind: 'code'; key: string; code: EidolonWorkspace; subject: Subject; choice: EidolonChoice } |
    { kind: 'inspection'; key: string; representation: Extract<EidolonRepresentation, { kind: 'lens' }>; title: string } |
    { kind: 'question'; key: string; reference: GuiQuestionReference; controller: QuestionController } | { kind: 'questions'; key: string } | null>(null)
  const [focused, setFocused] = useState(false)
  const [questions, setQuestions] = useState<GuiQuestionReference[]>([])
  const [questionError, setQuestionError] = useState<string | null>(null)
  const [hudRevision, setHudRevision] = useState(0)
  // These are local presentation handles, not a copy of pending question state.
  // Panel unmount/VR focus changes do not discard their shared drafts.
  const questionPresentations = useMemo(() => new Map<string, { controller: QuestionController; discovered: boolean }>(), [identity, agent])
  useEffect(() => () => {
    for (const { controller } of questionPresentations.values()) controller.close()
    questionPresentations.clear()
  }, [questionPresentations])
  useEffect(() => {
    setQuestions([])
    setQuestionError(null)
    if (!identity || !agent) return
    const hud = connectGuiHud(identity, agent, {
      projection(references) {
        const current = new Set(references.map(questionKey))
        for (const [key, presentation] of questionPresentations) {
          if (current.has(key)) presentation.discovered = true
          else if (presentation.discovered) {
            presentation.controller.close(); questionPresentations.delete(key)
            void library.current?.refresh()
          }
        }
        setQuestions(references); setQuestionError(null)
      },
      prepare(reference) {
        const key = questionKey(reference)
        let presentation = questionPresentations.get(key)
        if (!presentation) {
          presentation = { controller: questionController(identity, agent, reference, { deferOpen: true }), discovered: false }
          questionPresentations.set(key, presentation)
        }
        const retained = presentation
        return {
          activate() {
            if (questionPresentations.get(key) !== retained) return false
            if (!retained.controller.started) retained.controller.refresh()
            return true
          },
          dispose() {
            if (!retained.discovered && questionPresentations.get(key) === retained) {
              retained.controller.close(); questionPresentations.delete(key)
            }
          },
        }
      },
      discard() { setQuestions([]) },
      unavailable: setQuestionError,
    })
    return () => hud.close()
  }, [identity, agent, hudRevision, questionPresentations])
  const pick = useRef(setSelected)
  pick.current = setSelected
  // Async view reads are invalidated when the acting identity or target changes.
  const projectionScope = JSON.stringify([actorKey, view, spaceIdentity, mode])
  const projection = useRef(projectionScope)
  const context = useRef({ identity, agent, selected, view, mode, revision, spaceIdentity })
  context.current = { identity, agent, selected, view, mode, revision, spaceIdentity }
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
        const installed = ['quod:gui', 'quod:licence'].every(namespace =>
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
        world = createWorld(canvas.current, subject => pick.current(subject), value => { if (active) setImmersive(value) },
          error => {
            if (active) setStatus(error.message)
            else console.error('World resource or XR cleanup failed', error)
          },
          captured => { if (active) setNavigationActive(captured) },
          () => { if (active) setControllerRevision(n => n + 1) },
          state => { if (active) setXRState(state) })
        setScene(world)
      } catch (error) { setSceneError(String(error)) }
    }).catch(error => { if (active) setSceneError(String(error)) })
    return () => { active = false; void world?.dispose().catch(error => console.error('World teardown failed', error)) }
  }, [])

  useEffect(() => {
    scene?.setControllerMapping(null)
    if (!identity || !account || !scene) return
    const stream = connectControllerView(identity, account, {
      projection: mapping => scene.setControllerMapping(mapping),
      discard: () => scene.setControllerMapping(null),
      unavailable: reason => setToolError(`VR controller settings: ${reason}`),
    })
    return () => { stream.close(); scene.setControllerMapping(null) }
  }, [identity, account, scene])

  useEffect(() => {
    let active = true
    let stream: ReturnType<typeof connectWorldView> | undefined
    let terrainReady: boolean | undefined
    scene?.update(null)
    const sameScope = projection.current === projectionScope
    projection.current = projectionScope
    if (!sameScope) {
      library.current?.close(); library.current = null
      setMarks([])
      scene?.update({ marks: [], selection: 'unavailable' })
      setWorkspace(null)
      setFocused(false)
    }
    setSelected(null)
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
          const result = await readSpaceNavigation(identity, agent, space?.reference)
          if (!active) return
          setModes(result?.modes ?? [])
          setMissingLobby(!space && result === null)
          if (!result) { setStatus(space ? 'This world is unavailable or access was refused.' : 'This agent has no personal lobby yet.'); return }
          stream = connectWorldView(identity, agent, {
            projection(current) {
              if (!active) return
              const presented = scene?.update(current)
              setMarks(current.marks)
              setMovementHint(current.control?.jump ? ' · Space to jump'
                : current.selection === 'nonphysical' ? ' · Shift for faster movement' : '')
              setMissingLobby(!space && current.selection === 'unavailable')
              terrainReady = current.selection === 'active' ? current.terrainReady : undefined
              setStatus(terrainReady === false ? 'Loading terrain. Movement paused…' : { active: 'Physical space ready.', nonphysical: 'Space ready. Observer travel.',
                disabled: 'Physics is disabled. Body travel paused.', denied: 'Physics access denied. Body travel paused.',
                recovering: 'Physics is recovering. Body travel paused.', unavailable: current.marks.length
                  ? 'Physics unavailable. Body travel paused.' : 'The scene is unavailable. Check its setup and source.'
              }[current.selection])
              return presented
            },
            frame(current) {
              if (!active) return
              if (terrainReady !== current.terrainReady) {
                terrainReady = current.terrainReady
                setStatus(terrainReady === false ? 'Loading terrain. Movement paused…' : 'Physical space ready.')
              }
              return scene?.update(current)
            },
            refused(reason, reasons) { if (active) setStatus([reason, ...reasons].join(' ')) },
            refreshing() {
              if (active) { scene?.update(null); setStatus('Space updating. Movement paused…'); setRevision(n => n + 1) }
              return false
            },
            unavailable(reason) { if (active) { scene?.update(null); setStatus(reason) } },
          }, { world: result.reference, dependencies: result.dependencies, mode })
        } else {
          const result = await readLensView(identity, agent, 'work_licences', ['quod'])
          if (!active) return
          setMarks(result.marks ?? [])
          scene?.update({ marks: result.marks ?? [], selection: 'nonphysical' })
          setStatus(result.marks ? 'Licence lens · Quod release dependencies.'
            : 'The licence lens has no compatible representation for this data.')
        }
      } catch (error) {
        if (active) { scene?.update(null); setStatus(`Could not open this view: ${String(error)}`) }
      }
    }
    retireView.current = () => { active = false; stream?.close(); scene?.update(null) }
    void load()
    const online = () => setRevision(n => n + 1)
    window.addEventListener('online', online)
    return () => { active = false; stream?.close(); scene?.update(null); window.removeEventListener('online', online) }
  }, [identity, agent, view, mode, revision, viewUnavailable, scene, projectionScope])

  useEffect(() => {
    let active = true
    setEidolons(null)
    if (identity && agent && selected) {
      const subject = selected
      void readEntityEidolons(identity, agent, subject).then(choices => {
        if (active) setEidolons({ subject, choices })
      }).catch(error => {
        if (active) setEidolons({ subject, choices: [], error: String(error),
          accessDenied: error instanceof GoalFailure && error.accessDenied })
      })
    }
    return () => { active = false }
  }, [identity, agent, selected, inspectionRevision])

  const operations = useMemo<{ current: OperationController | null }>(() => ({ current: null }), [identity, agent])
  useEffect(() => () => operations.current?.close(), [operations])
  const openOperations = (subject?: Subject, kind: 'class' | 'entity' = 'entity') => {
    if (!identity || !agent) return
    const targets = subject?.anchor ? [{ namespace: subject.ontology, anchor: subject.anchor }]
      : [...ontologies.values()].map(ref => ({ namespace: ref.namespace, anchor: fromB64url(ref.anchor) }))
    const exact = subject ? operationSubject(targets[0], kind, subject.entity) : undefined
    if (operations.current) {
      if (!operations.current.open(targets, exact)) {
        setToolError('Finish or cancel the current operation before changing subject.'); return
      }
    }
    else {
      operations.current = operationController(identity, agent, targets, { close: () => setFocused(false),
        subject: reference => {
          if (reference.type !== 'compound' || reference.args.length !== 3) return
          const [ns, anchor, entity] = reference.args
          if (ns.type === 'binary' && anchor.type === 'binary' && anchor.value.length === 32)
            openOperations({ ontology: new TextDecoder('utf-8', { fatal: true }).decode(ns.value), anchor: anchor.value, entity })
        } },
        { subject: exact })
    }
    setWorkspace({ kind: 'operation', key: '@operations', controller: operations.current }); setFocused(true)
  }
  const openConsole = async (subject: Subject) => {
    if (!identity || !agent || openingTool) return
    const request = context.current
    setToolError(null)
    try {
      const choices = await readEntityEidolons(identity, agent, subject)
      const choice = choices.find(choice => choice.purpose === 'workspace' && choice.style === 'proof_console')
      if (!currentRequest(request)) return
      if (!choice) throw new Error('No console workspace is offered for this subject.')
      await openEidolon(choice, subject)
    } catch (error) {
      if (currentRequest(request)) setToolError(`Could not open the console: ${String(error)}`)
    }
  }

  const openLibraryController = (reference: { namespace: string; anchor: Uint8Array },
    form: Parameters<typeof spaceLibraryController>[3], key: string) => {
    if (!identity || !agent) return
    library.current?.close()
    const controller = spaceLibraryController(identity, agent, reference, form, {
      close: () => setFocused(false), return: () => navigate(null),
      enter: (target, label) => navigate(target, label), question: openQuestion,
    })
    library.current = controller
    setWorkspace({ kind: 'library', key, controller }); setFocused(true)
  }
  const openLibrary = async () => {
    if (!identity || !agent || openingTool) return
    const request = context.current
    setOpeningTool(true); setToolError(null)
    try {
      const lobby = await readSpaceNavigation(identity, agent)
      if (!lobby) throw new Error('The personal lobby has not been set up.')
      const reply = await signedGoal(identity, { mode: 'read', agent,
        goal: anchoredGoal(lobby.reference, compound('world_library_workspace', [variable('View')])) })
      const form = readGuiView(singleBinding(reply, 'View'))
      if (currentRequest(request)) openLibraryController(lobby.reference, form, `library:${spaceKey(lobby.reference)}`)
    } catch (error) {
      if (currentRequest(request)) setToolError(`Could not open My worlds: ${String(error)}`)
    } finally { if (currentRequest(request)) setOpeningTool(false) }
  }

  const openEidolon = async (choice: EidolonChoice, subject = selected) => {
    if (!identity || !agent || !subject?.anchor || openingTool) return
    if (choice.purpose === 'operation(instance)' || choice.purpose === 'operation(class)') {
      openOperations(subject, choice.purpose === 'operation(class)' ? 'class' : 'entity'); return
    }
    const request = context.current
    const key = JSON.stringify([subject.ontology, [...subject.anchor], renderTerm(subject.entity),
      choice.recipe.namespace, [...choice.recipe.anchor], choice.recipe.name])
    setOpeningTool(true)
    setToolError(null)
    try {
      const representation = await readEidolon(identity, agent, subject, choice)
      if (representation.kind === 'workspace' && representation.controller === 'prolog_editor') codeForm(representation.workspace.view)
      if (!currentRequest(request)) return
      if (representation.kind === 'workspace' && representation.controller === 'space_library') {
        openLibraryController(representation.workspace.target, representation.workspace.view, key)
      } else if (representation.kind === 'workspace' && representation.controller === 'proof_console') {
        setWorkspace({ kind: 'proof', key, view: proofForm(representation.workspace.view) })
      } else setWorkspace(representation.kind === 'workspace'
        ? { kind: 'code', key, code: representation.workspace, subject, choice }
        : { kind: 'inspection', key, representation, title: inspectionLabel(choice) })
      setFocused(true)
    } catch (error) {
      if (currentRequest(request)) setToolError(`Could not open the representation: ${String(error)}`)
      return error instanceof Error ? error : new Error(String(error))
    } finally {
      if (currentRequest(request)) setOpeningTool(false)
    }
  }

  const controllerOperations = useMemo(() => ({ identity, account, current: null as OperationController | null }), [identity, account])
  useEffect(() => () => controllerOperations.current?.close(), [controllerOperations])
  const openControllerSettings = () => {
    const { identity, account } = controllerOperations
    if (!identity || !account) return
    const target = { namespace: account.namespace, anchor: typeof account.anchor === 'string' ? fromB64url(account.anchor) : account.anchor }
    const subject = operationSubject(target, 'entity', readTerm(account.instanceText.replace(/\.\s*$/, '')))
    if (controllerOperations.current) {
      if (!controllerOperations.current.open([target], subject)) return
    } else controllerOperations.current = operationController(identity, account, [target],
      { close: () => setFocused(false) }, { subject })
    setWorkspace({ kind: 'operation', key: '@controller-settings', controller: controllerOperations.current }); setFocused(true)
  }
  const controllerActions = useRef({ settings: openControllerSettings })
  controllerActions.current = { settings: openControllerSettings }
  const controllerPresentation = useMemo(() => controllerPanel(() => scene,
    { close: () => setFocused(false), settings: () => controllerActions.current.settings() }), [scene])
  useEffect(() => controllerPresentation.refresh(), [controllerPresentation, controllerRevision])
  const openControllers = () => {
    setWorkspace({ kind: 'controllers', key: '@controllers', controller: controllerPresentation }); setFocused(true)
  }

  const toolChoices = eidolons?.subject === selected ? eidolons.choices.filter(choice => choice.purpose === 'workspace' || choice.purpose.startsWith('operation(')) : []
  const selectedMenu = toolChoices.map((choice, index) => ({ id: `@eidolon/${index}`, label: choice.style, view: choice.style }))
  const activate = useRef<(entry: MenuEntry) => void>(() => {})
  const openQuestion = (reference: GuiQuestionReference) => {
    if (!identity || !agent) return
    const key = questionKey(reference)
    let presentation = questionPresentations.get(key)
    if (!presentation) {
      presentation = { controller: questionController(identity, agent, reference), discovered: true }
      questionPresentations.set(key, presentation)
    }
    presentation.discovered = true
    if (!presentation.controller.started) presentation.controller.refresh()
    setWorkspace({ kind: 'question', key, reference, controller: presentation.controller })
    setFocused(true)
  }
  activate.current = entry => {
    if (entry.id === '@xr/exit') void scene?.exitImmersive().catch(error => setXRError(String(error)))
    else if (entry.id === '@controllers') openControllers()
    else if (entry.id === '@gui/questions') {
      setWorkspace({ kind: 'questions', key: '@gui/questions' }); setFocused(true)
    } else if (entry.id === '@space/library') void openLibrary()
    else if (entry.id === '@space/return') navigate(null)
    else if (entry.id === '@operations') openOperations()
    else if (entry.id.startsWith('@eidolon/')) void openEidolon(toolChoices[Number(entry.id.slice(9))])
  }
  useEffect(() => {
    const entries = [...(selectedMenu ?? []), ...(identity && agent ? [{
      id: '@gui/questions', label: `Questions (${questions.length})`, view: 'gui_questions',
    }, { id: '@controllers', label: 'VR controllers', view: 'controllers' }, { id: '@space/library', label: 'My worlds', view: 'space_library' },
      { id: '@operations', label: 'Create / operations', view: 'operations' },
      ...(space || view !== 'lobby' ? [{ id: '@space/return', label: 'Return to lobby', view: 'lobby' }] : [])] : [])]
    if (xrState === 'presenting') entries.push({ id: '@xr/exit', label: 'Exit VR', view: 'xr_exit' })
    scene?.setActionMenu(entries, entry => activate.current(entry))
  }, [scene, selected, selectedMenu, identity, agent, questions.length, spaceIdentity, view, xrState])

  const selectedAccount = account && account.namespace === agent?.namespace &&
    account.anchor === agent?.anchor && account.instanceText === agent?.instanceText
  const devices = marks.filter(mark => mark.depicts?.anchor)
  const consoleSubject = devices.find(mark => mark.id === 'console')?.depicts
  const inspectionLabel = (choice: EidolonChoice) => choice.purpose === 'prolog' ? 'View Prolog source'
    : ({ policy: 'View ACL rules', interfaces: 'View declared interfaces', routes: 'View live routes' } as Record<string, string>)[choice.style] ?? choice.style
  const sourceChoices = eidolons?.subject === selected
    ? eidolons.choices.filter(choice => (choice.purpose === 'prolog' && choice.style === 'source') ||
        (choice.purpose === 'inspection' && ['policy', 'interfaces', 'routes'].includes(choice.style))) : []
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
    <canvas ref={canvas} className="world-canvas" aria-label={space?.label ?? "Personal lobby"} tabIndex={0} />
    {navigationActive && <div className="world-crosshair" aria-hidden="true" />}
    <div className={`world-navigation-hint${navigationActive ? ' active' : ''}`} aria-live="polite">
      {`${navigationActive ? 'Mouse to look' : 'Click the world to explore'} · ZQSD, WASD or arrows to move${movementHint}${navigationActive ? ' · Esc to release' : ''}`}
    </div>
    <header className={`world-header${navigationActive ? ' navigation-active' : ''}`}>
      <a href="/" className="world-brand">quod <span>∴</span></a>
      <SessionControls />
      <a href="/explorer/">Explorer ↗</a>
    </header>
    <section className={`world-panel${navigationActive ? ' navigation-active' : ''}`} aria-label="World controls">
      <p className="world-eyebrow">YOUR SPACE</p>
      <h1>{space?.label ?? 'Personal lobby'}</h1>
      <p role="status">{sessionError ?? status}</p>
      {sceneError && <>
        <p>The 3D view could not start, so Enter VR is unavailable. You can still open the console below.</p>
        <details>
          <summary>3D startup error</summary>
          <p>{sceneError}</p>
        </details>
      </>}
      <div className="world-controls">
        {view === 'lobby' && !space
          ? <button className="world-primary" disabled={!consoleSubject || openingTool}
              onClick={() => consoleSubject && void openConsole(consoleSubject)}>
              {openingTool ? 'Opening…' : 'Open console'}</button>
          : <button className="world-primary" onClick={() => navigate(null)}>Return to lobby</button>}
        <button disabled={!identity || !agent || openingTool} onClick={() => openOperations()}>Create / operations</button>
        <button disabled={!identity || !agent || openingTool} onClick={() => void openLibrary()}>My worlds</button>
        <button disabled={!scene || (xrState === 'ready' ? !vr.available : !['starting', 'presenting'].includes(xrState))}
          aria-describedby="vr-availability" onClick={() => {
            setXRError(null)
            const operation = xrState === 'ready' ? scene?.immersive() : scene?.exitImmersive()
            void operation?.catch(error => setXRError(String(error)))
          }}>{xrState === 'starting' ? 'Cancel VR entry' : xrState === 'presenting' ? 'Exit VR'
            : xrState === 'stopping' ? 'Ending VR…' : xrState === 'preparing' ? 'Preparing VR…' : 'Enter VR'}</button>
        {missingLobby && selectedAccount &&
          <button disabled={busy || unresolved > 0} onClick={() => void finishSetup()}>Finish account setup</button>}
      </div>
      <p id="vr-availability" className="world-help">{sceneError ? 'VR requires a working 3D view.'
        : xrState === 'blocked' ? 'VR release is unconfirmed. Use the headset or browser exit control.'
        : xrError ?? vr.reason}</p>
      {view === 'lobby' && !space && !consoleSubject && <p>The console is unavailable until its lobby view loads.</p>}
      {toolError && <p role="alert">{toolError}</p>}
      {selected && selectedMenu.length > 0 && <div className="world-menu" aria-label="Selected object actions">
        <p>{renderTerm(selected.entity)}</p>
        {selectedMenu.map((entry, index) => <button key={entry.id} disabled={openingTool}
          onClick={() => void openEidolon(toolChoices[index])}>{entry.label}</button>)}
        <button onClick={() => setSelected(null)}>Dismiss selection</button>
      </div>}
      {identity && agent && <section aria-label="Pending questions">
        {questions.length > 0 && <h2>Questions awaiting your attention</h2>}
        {questions.map((reference, index) => <button key={questionKey(reference)} onClick={() => openQuestion(reference)}>Question {index + 1} · {reference.namespace}</button>)}
        {questionError && <p role="status">Questions unavailable: {questionError}</p>}
        <button onClick={() => setHudRevision(value => value + 1)}>Reload questions</button>
      </section>}
      <details className="world-advanced">
        <summary>Advanced</summary>
        <div className="world-controls">
          <label>Scene <select aria-label="Scene" value={view} onChange={event => { retireSpace(); setDestination(null); setView(event.target.value) }}>
            <option value="lobby">Personal lobby</option>
            <option value="licence" disabled={licenceUnavailable !== null}>Software licences</option>
          </select></label>
          {view === 'lobby' && <label>Appearance <select aria-label="Appearance" value={mode} onChange={event => { retireSpace(); setMode(event.target.value) }}>
            {modes.map(purpose => <option key={purpose} value={purpose}>
              {purpose === 'playing' ? 'Normal' : purpose === 'edition' ? 'Structure' : purpose}
            </option>)}
          </select></label>}
          <button onClick={() => setRevision(n => n + 1)} disabled={!identity || !agent}>Reload scene</button>
          <button onClick={openControllers} disabled={!identity || !account}>VR controllers</button>
        </div>
        <p className="world-help">Structure changes the visual representation; it does not enable world editing.</p>
        {licenceUnavailable && <p>Software licences: {licenceUnavailable}</p>}
        <h2>Inspect objects and Prolog knowledge</h2>
        <p>Choose a target to see its offered representations. Access depends on your permissions.</p>
        <label>Inspect <select aria-label="Inspect" value="" onChange={event => {
          const value = event.target.value
          if (value.startsWith('object:')) setSelected(devices[Number(value.slice(7))]?.depicts ?? null)
          else {
            const ref = ontologies.get(value)
            if (ref) setSelected(ontologySubject({ namespace: ref.namespace, anchor: fromB64url(ref.anchor) }))
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
          {eidolons?.subject !== selected ? <p>Loading representations…</p>
            : eidolons.accessDenied ? <p>Inspection is restricted for this target. Your current account does not have access.</p>
            : eidolons.error ? <>
              <p role="alert">Representations could not be loaded: {eidolons.error}</p>
              <button onClick={() => setInspectionRevision(value => value + 1)}>Retry inspection</button>
            </> : sourceChoices.length === 0 ? <p>No supported representation is offered for this target.</p>
              : sourceChoices.map((choice, index) => <button key={index} disabled={openingTool}
                  onClick={() => void openEidolon(choice)}>
                  {inspectionLabel(choice)}
                </button>)}
          <button onClick={() => setSelected(null)}>Clear inspection</button>
        </div>}
      </details>
    </section>
    {workspace && <section className="world-workspace" hidden={!focused || immersive} aria-label="Focused console">
      {workspace.kind === 'library' || workspace.kind === 'operation' || workspace.kind === 'controllers'
        ? <GuiWorkspace controller={workspace.controller} scene={scene} visible={focused} />
        : workspace.kind === 'questions'
        ? <GuiQuestionList references={questions} status={questionError} scene={scene} visible={focused}
            select={openQuestion} reload={() => setHudRevision(value => value + 1)} onClose={() => setFocused(false)} />
        : workspace.kind === 'question'
        ? <GuiQuestion key={workspace.key} reference={workspace.reference} controller={workspace.controller}
            scene={scene} visible={focused}
            onClose={() => setFocused(false)} />
        : workspace.kind === 'proof'
        ? <ConsoleWorkspace view={workspace.view} onClose={() => setFocused(false)} scene={scene} visible={focused} />
        : workspace.kind === 'inspection'
        ? <OntologyInspection representation={workspace.representation} title={workspace.title} onClose={() => setFocused(false)} />
        : <PrologEditor workspace={workspace.code} onClose={() => setFocused(false)} scene={scene} visible={focused}
            onRefresh={async () => {
              const error = await openEidolon(workspace.choice, workspace.subject)
              if (error) throw error
            }} />}
    </section>}
  </div>
}
