import { createRoot } from 'react-dom/client'
import { flushSync } from 'react-dom'
import { GuiQuestion } from '../src/GuiQuestion'
import { SessionContext } from '../src/session-context'
import type { SessionState } from '../src/session-context'
import { signedOperationJournal } from '../../client/src/operation-journal.js'
import { atom } from '../../client/src/prolog-term.js'
import type { WorkspacePanelModel, WorldScene } from '../../client/src/world-scene.js'

const anchor = new Uint8Array(32)
const identity = { networkId: anchor, provider: { publicKey: anchor, sign: async () => new Uint8Array(64) },
  session: { session_id: 'gui-browser-fixture', expires_ms: Date.now() + 600000 } }
const agent = { namespace: 'gui:browser:human', anchor, instanceText: 'human.' }
const reference = { namespace: 'gui:browser:responder', anchor, question: atom('browser_question') }
const session = { identity, agent } as unknown as SessionState
const digest = `<<"${'a'.repeat(32)}">>`
const tree = 'component(form,form,[property(label,<<"Settings">>)],[' +
  'component(name,text_box,[property(label,<<"Name">>)],[]),' +
  'component(save,button,[property(label,<<"Save">>)],[])])'
const value = `question_form(form_ref(<<"app">>,${digest},form),` +
  `agent_instance_ref(<<"responder">>,${digest},handler),${digest},awaiting,` +
  `form_view(${digest},${tree},${digest},[field(name,<<"Default">>)],save))`
const posts: { url: string; request: string }[] = []
const errors: string[] = []
window.addEventListener('error', event => errors.push(event.message))
window.addEventListener('unhandledrejection', event => errors.push(String(event.reason)))
class Socket {
  onopen?: () => void
  onmessage?: (event: { data: string }) => void
  constructor() { queueMicrotask(() => this.onopen?.()) }
  async send(json: string) {
    const message = JSON.parse(json)
    if (message.type !== 'open') throw new Error('Unexpected GUI frame credit')
    const request = Uint8Array.from(atob(message.request.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0))
    const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', request))
    const view = btoa(String.fromCharCode(...hash)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
    this.onmessage?.({ data: JSON.stringify({ type: 'projection', kind: 'gui_question', view,
      height: '1', expires_ms: String(Date.now() + 30000), value }) })
  }
  close() {}
}
const originalSocket = globalThis.WebSocket, originalFetch = globalThis.fetch
Object.assign(globalThis, { WebSocket: Socket, fetch: async (url: string, options: RequestInit) => {
  const body = JSON.parse(String(options.body)); posts.push({ url, request: body.request })
  if (url === '/api/goals/execute') throw new Error('fixture lost reply')
  if (url !== '/api/goals/outcomes') throw new Error('unexpected fixture request')
  return Response.json({ result: 'operation_outcome', terminal: true, status: 'committed' })
} })
const root = createRoot(document.getElementById('fixture')!)
let spatial: WorkspacePanelModel | null = null
const scene = { setWorkspace(model: WorkspacePanelModel | null) { spatial = model } } as WorldScene
const draw = () => flushSync(() => root.render(<SessionContext.Provider value={session}>
  <GuiQuestion reference={reference} scene={scene} visible onClose={() => {}} />
</SessionContext.Provider>))
function button(text: string) {
  return [...document.querySelectorAll('button')].find(node => node.textContent === text)!
}
function input(label: string) {
  const node = [...document.querySelectorAll('label')].find(node => node.textContent === label)!
  return document.getElementById(node.htmlFor) as HTMLInputElement
}
function until(predicate: () => boolean) {
  if (predicate()) return Promise.resolve()
  return new Promise<void>((resolve, reject) => {
    const observer = new MutationObserver(() => {
      if (predicate()) { observer.disconnect(); clearTimeout(deadline); resolve() }
    })
    const deadline = setTimeout(() => { observer.disconnect(); reject(new Error('fixture DOM transition missing')) }, 10000)
    observer.observe(document.getElementById('fixture')!, { subtree: true, childList: true, attributes: true, characterData: true })
  })
}
Object.assign(window, { exerciseGuiQuestion: async () => {
  const journal = signedOperationJournal()
  // Only this fixture's actor; never clear other browser operations.
  for (const row of await journal.list()) if (row.agent.namespace === agent.namespace) await journal.delete(row.id)
  try {
    draw(); await until(() => !!button('Save') && !button('Save').disabled)
    const name = input('Name')
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(name, 'Browser answer')
    name.dispatchEvent(new Event('input', { bubbles: true }))
    flushSync(() => spatial!.edit('name', 'Shared spatial answer'))
    const sharedDraft = input('Name').value === 'Shared spatial answer'
    const beforeClick = spatial!
    flushSync(() => button('Save').click())
    beforeClick.invoke('save')
    await until(() => !button('Check saved operation').disabled)
    const lockedAfterLoss = button('Save').disabled && input('Name').disabled
    flushSync(() => root.render(null))
    draw(); await until(() => !!button('Save') && !button('Check saved operation').disabled)
    const lockedAfterReopen = button('Save').disabled
    flushSync(() => button('Save').click())
    flushSync(() => button('Check saved operation').click())
    await until(() => input('Status').value === 'Saved operation: committed.')
    const result = { sharedDraft, lockedAfterLoss, lockedAfterReopen, lockedAfterResolution: button('Save').disabled,
      executeCount: posts.filter(post => post.url === '/api/goals/execute').length,
      outcomeCount: posts.filter(post => post.url === '/api/goals/outcomes').length,
      exactRequest: posts.length === 2 && posts[0].request === posts[1].request,
      retained: (await journal.list()).filter(row => row.agent.namespace === agent.namespace).length, errors }
    return result
  } finally {
    flushSync(() => root.render(null))
    Object.assign(globalThis, { WebSocket: originalSocket, fetch: originalFetch })
  }
} })
