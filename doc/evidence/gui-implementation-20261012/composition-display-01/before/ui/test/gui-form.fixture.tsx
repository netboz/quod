import { inputVariants, inputDefaults } from '../../client/test/gui-input-variants.js'
import { createRoot } from 'react-dom/client'
import { flushSync } from 'react-dom'
import { GuiForm } from '../src/GuiForm'
import { readGuiView } from '../../client/src/world.js'
import type { WorkspacePanelModel } from '../../client/src/world-scene.js'

const view = readGuiView(`component(settings,form,[property(label,<<"Instrument setup">>)],[
  component(name,text_box,[property(label,<<"Name">>),property(help,<<"Name this instrument.">>),property(required,true),property(max_bytes,12)],[]),
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

function input(label: string): HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement {
  const node = [...document.querySelectorAll('label')].find(item => item.textContent === label)
  if (!node) throw new Error(`Missing label: ${label}`)
  return document.getElementById(node.htmlFor) as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement
}
function enter(label: string, value: string) {
  const control = input(label)
  const proto = control instanceof HTMLSelectElement ? HTMLSelectElement.prototype
    : control instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype
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
  const rejected = (event: PromiseRejectionEvent) => errors.push(String(event.reason))
  window.addEventListener('error', record)
  window.addEventListener('unhandledrejection', rejected)
  try {
    const initialFont = parseFloat(getComputedStyle(input('Name')).fontSize)
    const beforeScale = JSON.stringify(model.values)
    click('Larger text')
    checks.largerTextReflows = parseFloat(getComputedStyle(input('Name')).fontSize) > initialFont &&
      getComputedStyle(document.querySelector('.gui-row')!).gridTemplateColumns.split(' ').length === 1 &&
      JSON.stringify(model.values) === beforeScale
    click('Smaller text')
    checks.textScaleRestored = parseFloat(getComputedStyle(input('Name')).fontSize) === initialFont
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
    enter('Angle (degrees)', '1.5')
    click('Increase Angle')
    checks.offGridRotaryRetained = model.values.angle === '1.5' && input('Angle (degrees)').getAttribute('aria-invalid') === 'true'
    enter('Angle (degrees)', '180')
    const name = view.fields.find(field => field.role === 'name')!
    name.readonly = true; draw(); input('Name').focus()
    checks.readonlyRemainsFocusable = document.activeElement === input('Name') &&
      (input('Name') as HTMLInputElement).readOnly && !input('Name').disabled
    enter('Name', 'Forbidden')
    checks.readonlyCannotEdit = model.values.name === 'Entered'
    checks.helpIsDescribed = document.getElementById(input('Name').getAttribute('aria-describedby')!)!.textContent!.includes('Name this instrument.')
    name.readonly = false
    const tuning = view.fields.find(field => field.role === 'tuning')!
    tuning.enabled = false; draw(); click('Increase Level')
    checks.disabledContainerInherited = input('Level').disabled && input('Angle (degrees)').disabled && model.values.level === '7'
    tuning.enabled = true; draw()
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
    model.view = inputVariants(); model.values = inputDefaults(); draw()
    enter('Notes', 'one\ntwo')
    click('Increase Count')
    checks.multilineAndNumber = model.values.notes === 'one\ntwo' && model.values.count === '1' &&
      document.querySelector('.gui-number input[type="range"]') === null
    const choose = (label: string) => {
      const node = [...document.querySelectorAll('.gui-choices label')].find(item => item.textContent === label)!
      flushSync(() => (node.querySelector('input') as HTMLInputElement).click())
    }
    flushSync(() => input('Agreement').click())
    flushSync(() => input('Power').click())
    choose('Beta'); choose('Item A'); choose('Item B'); choose('Item A')
    checks.typedVariants = model.values.agree === 'true' && model.values.power === 'true' &&
      model.values.radio === 'b' && model.values.items === '[item(b)]' && input('Power').getAttribute('role') === 'switch'
    const variants = JSON.stringify(model.values)
    model.locked = true; draw()
    flushSync(() => input('Agreement').click())
    choose('Alpha'); choose('Item A'); click('Increase Count')
    checks.lockedVariants = JSON.stringify(model.values) === variants && input('Notes').disabled && input('Count').disabled
    await new Promise<void>(resolve => {
      const channel = new MessageChannel()
      channel.port1.onmessage = () => { channel.port1.close(); channel.port2.close(); resolve() }
      channel.port2.postMessage(null)
    })
    return { checks, errors }
  } finally {
    window.removeEventListener('error', record)
    window.removeEventListener('unhandledrejection', rejected)
  }
} })
