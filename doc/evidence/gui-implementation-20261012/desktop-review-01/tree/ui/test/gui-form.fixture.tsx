import { createRoot } from 'react-dom/client'
import { flushSync } from 'react-dom'
import { GuiForm } from '../src/GuiForm'
import { readGuiView } from '../../client/src/world.js'
import type { WorkspacePanelModel } from '../../client/src/world-scene.js'

const view = readGuiView(`component(settings,form,[property(label,<<"Instrument setup">>)],[
  component(name,text_box,[property(label,<<"Name">>),property(required,true),property(max_bytes,12)],[]),
  component(mode,selection,[property(label,<<"Waveform">>),property(options,[option(wave(sine),<<"Sine">>),option(wave(square),<<"Square">>)])],[]),
  component(tuning,container,[property(label,<<"Tuning">>),property(layout,row)],[
    component(level,slider,[property(label,<<"Level">>),property(range,range(-2,8,3))],[]),
    component(angle,rotary_knob,[property(label,<<"Angle">>),property(range,range(0,359,1)),property(unit,degrees)],[])]),
  component(apply,button,[property(label,<<"Apply settings">>)],[])])`)
const root = createRoot(document.getElementById('fixture')!)
const events: unknown[] = []
const model: WorkspacePanelModel = {
  view, scope: 'gui:independent-instrument', values: { name: 'Oscillator', mode: 'wave(sine)', level: '1', angle: '90' },
  locked: false, enabled: { apply: true },
  edit(role, value) { model.values = { ...model.values, [role]: value }; draw() },
  invoke(role) { events.push({ role, values: { ...model.values } }) },
  close() { events.push('close') },
}
function draw() { flushSync(() => root.render(<GuiForm model={model} />)) }
draw()

function input(label: string): HTMLInputElement | HTMLSelectElement {
  const node = [...document.querySelectorAll('label')].find(item => item.textContent === label)
  if (!node) throw new Error(`Missing label: ${label}`)
  return document.getElementById(node.htmlFor) as HTMLInputElement | HTMLSelectElement
}
function enter(label: string, value: string) {
  const control = input(label)
  const proto = control instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype
  Object.getOwnPropertyDescriptor(proto, 'value')!.set!.call(control, value)
  control.dispatchEvent(new Event(control instanceof HTMLSelectElement ? 'change' : 'input', { bubbles: true }))
}
function click(label: string) {
  const control = [...document.querySelectorAll('button')].find(item =>
    item.getAttribute('aria-label') === label || item.textContent === label)
  if (!control) throw new Error(`Missing button: ${label}`)
  flushSync(() => control.click())
}

Object.assign(window, { exerciseGuiForm: async () => {
  const checks: Record<string, boolean> = {}
  const errors: string[] = []
  const record = (event: ErrorEvent) => errors.push(String(event.error ?? event.message))
  window.addEventListener('error', record)
  try {
    enter('Name', 'Entered')
    enter('Waveform', 'wave(square)')
    click('Increase Level')
    checks.nativeChangesReachController = model.values.name === 'Entered' && model.values.mode === 'wave(square)' && model.values.level === '4'
    enter('Level', 'bad')
    checks.invalidDraftVisible = model.values.level === 'bad' && input('Level').value === 'bad' && input('Level').getAttribute('aria-invalid') === 'true'
    click('Increase Level')
    checks.invalidDraftNotReplaced = model.values.level === 'bad'
    enter('Level', '7')
    enter('Angle (degrees)', '180')
    click('Apply settings')
    checks.submissionUsesCurrentDraft = JSON.stringify(events.at(-1)) === JSON.stringify({role:'apply',values:{name:'Entered',mode:'wave(square)',level:'7',angle:'180'}})
    enter('Name', 'ééééééé')
    checks.utf8Feedback = input('Name').getAttribute('aria-invalid') === 'true'
    model.values.mode = 'unknown(value)'; draw()
    checks.unknownSelectionNotSubstituted = input('Waveform').value === 'unknown(value)' && input('Waveform').getAttribute('aria-invalid') === 'true'
    input('Name').focus()
    model.locked = true; model.enabled.apply = false; draw()
    const count = events.length
    click('Apply settings')
    checks.lockDisablesEntry = input('Name').disabled && input('Level').disabled && input('Angle (degrees)').disabled && events.length === count
    checks.controlsOpaque = [...document.querySelectorAll('.gui-field input,.gui-field select')].every(element => getComputedStyle(element).opacity === '1')
    checks.reachableTargetSizes = [...document.querySelectorAll('button,input,select')].every(element => element.getBoundingClientRect().height >= 44)
    click('Opaque')
    checks.opaqueAlternative = getComputedStyle(document.querySelector('.gui-form')!).backgroundColor === 'rgb(25, 43, 50)'
    checks.noHorizontalOverflow = document.documentElement.scrollWidth <= window.innerWidth
    model.locked = false; model.enabled.apply = true
    model.values = { name: 'Oscillator', mode: 'wave(sine)', level: '1', angle: '90' }; draw()
    await new Promise<void>(resolve => {
      const channel = new MessageChannel()
      channel.port1.onmessage = () => { channel.port1.close(); channel.port2.close(); resolve() }
      channel.port2.postMessage(null)
    })
    return { checks, errors }
  } finally { window.removeEventListener('error', record) }
} })
