import { remainingView, guiAssetFixture } from './gui-remaining.js'
import { createWorld } from '../src/world-scene.js'
import { EngineStore } from '@babylonjs/core/Engines/engineStore.js'

// Exercise the production spatial adapter and XR entry. This fixture records
// local control input; lifecycle/authority are covered by the signed-owner tests.
const asset = await guiAssetFixture()
const report = { immersive: false, entries: 0, edits: [], actions: [], submissions: [], errors: [], controls: [] }
const status = document.querySelector('#status')
const world = createWorld(document.querySelector('#scene'), () => {}, active => {
  report.immersive = active
  if (active) report.entries++
  status.textContent = active ? 'Headset active. Use the controllers to try the form.' : 'Desktop view.'
}, error => { report.errors.push(String(error)); status.textContent = String(error) })
world.update({ marks: [], selection: 'nonphysical' })
const model = {
  view: { title: 'Instrument configuration', fields: [
    { role: 'general', kind: 'container', label: 'General', children: [
      { role: 'name', kind: 'text_box', label: 'Run name', required: true, maxBytes: 128 },
      { role: 'mode', kind: 'selection', label: 'Mode', options: [
        { value: 'sweep', label: 'Sweep' }, { value: 'hold', label: 'Hold' }] },
      { role: 'enabled', kind: 'toggle', label: 'Enabled' },
    ] },
    { role: 'tuning', kind: 'container', label: 'Tuning', children: [
      { role: 'gain', kind: 'slider', label: 'Gain', range: { min: 0, max: 100, step: 1 }, unit: 'percent' },
      { role: 'phase', kind: 'rotary_knob', label: 'Phase', range: { min: 0, max: 359, step: 1 }, unit: 'degrees' },
    ] },
    { role: 'channels', kind: 'selection', label: 'Active channels', options: [
      { value: '[left]', label: 'Left' }, { value: '[right]', label: 'Right' },
      { value: '[left,right]', label: 'Stereo' }] },
    { role: 'notes', kind: 'text_area', label: 'Notes' },
    { role: 'record', kind: 'button', label: 'Record control check' },
  ] },
  scope: 'Hardware check — local values only', locked: false,
  values: { name: 'Vive check', mode: 'hold', enabled: 'true', gain: '20', phase: '0', channels: '[left]', notes: '' },
  enabled: { record: true, apply: true, icon_action: true },
  edit(role, value) {
    report.edits.push({ role, value })
    model.values[role] = value
    world.setWorkspace(model)
  },
  invoke(role) {
    report.actions.push(role)
    if (role === 'record') {
      report.submissions.push({ ...model.values })
      status.textContent = `Recorded control check ${report.submissions.length}.`
      model.scope = status.textContent
      world.setWorkspace(model)
    }
  },
  close() { world.setWorkspace(null) },
}
const instrument = model.view.fields.filter(field => field.role !== 'record')
model.view.fields = [{ role: 'hardware_sections', kind: 'tabs', label: 'Control checks', children: [
  { role: 'instrument', kind: 'panel', label: 'Instrument', children: instrument },
  { role: 'additional', kind: 'panel', label: 'Tables, images and dialogs', children: remainingView(asset.digest).fields },
  { role: 'variants', kind: 'grid', label: 'Input alternatives', layout: 'grid', columns: 2, children: [
    { role: 'count', kind: 'number_input', label: 'Count', range: { min: 0, max: 20, step: 1 } },
    { role: 'confirm', kind: 'checkbox', label: 'Confirmed' },
    { role: 'radio', kind: 'radio_group', label: 'Review mode', options: [{ value: 'a', label: 'Alpha' }, { value: 'b', label: 'Beta' }] },
    { role: 'items', kind: 'selectable_list', label: 'Items', multiple: true, options: [{ value: 'a', label: 'Item A' }, { value: 'b', label: 'Item B' }] },
    { role: 'progress', kind: 'progress', label: 'Progress example', percent: 65 },
    { role: 'help', kind: 'help', label: 'Try larger text, opacity, Move and Recenter. Record when done.' },
  ] },
] }, { role: 'record', kind: 'button', label: 'Record control check' }]
Object.assign(model.values, { outside: 'Outside draft', rows: '[]', note: '', flag: 'false', count: '1', confirm: 'false', radio: 'a', items: '[]' })
const controls = fields => fields.flatMap(field => [{ role: field.role, kind: field.kind }, ...controls(field.children ?? [])])
report.controls = controls(model.view.fields)
document.querySelector('#show').onclick = () => world.setWorkspace(model)
document.querySelector('#enter').onclick = () => world.immersive().catch(error => {
  report.errors.push(String(error)); status.textContent = String(error)
})
window.addEventListener('error', event => report.errors.push(event.message))
window.addEventListener('unhandledrejection', event => report.errors.push(String(event.reason)))
window.addEventListener('pagehide', () => { world.dispose(); asset.restore() }, { once: true })
window.guiHardwareReport = () => structuredClone(report)
window.guiHardwareOpacity = value => {
  const texture = EngineStore.LastCreatedScene.getMeshByName('workspace')?.material.emissiveTexture
  if (!texture) throw new Error('Headset panel is not installed')
  texture.getControlByName('workspace-opacity').value = value
}
world.setWorkspace(model)

window.guiHardwareBackground = value => {
  if (!Number.isFinite(value) || value < 0 || value > 1) throw new Error('Background must be between 0 and 1')
  EngineStore.LastCreatedScene.clearColor.set(value, value, value, 1)
  report.background = value
}
