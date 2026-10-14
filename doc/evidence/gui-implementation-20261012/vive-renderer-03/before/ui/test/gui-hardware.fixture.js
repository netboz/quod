import { createWorld } from '../../client/src/world-scene.js'
import { EngineStore } from '@babylonjs/core/Engines/engineStore.js'

// Exercise the production spatial adapter and XR entry. This fixture records
// local control input; lifecycle/authority are covered by the signed-owner tests.
const report = { immersive: false, entries: 0, edits: [], submissions: [], errors: [] }
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
      { role: 'enabled', kind: 'selection', label: 'Enabled', options: [
        { value: 'true', label: 'Enabled' }, { value: 'false', label: 'Disabled' }] },
    ] },
    { role: 'tuning', kind: 'container', label: 'Tuning', children: [
      { role: 'gain', kind: 'slider', label: 'Gain', range: { min: 0, max: 100, step: 1 }, unit: 'percent' },
      { role: 'phase', kind: 'rotary_knob', label: 'Phase', range: { min: 0, max: 359, step: 1 }, unit: 'degrees' },
    ] },
    { role: 'channels', kind: 'selection', label: 'Active channels', options: [
      { value: '[left]', label: 'Left' }, { value: '[right]', label: 'Right' },
      { value: '[left,right]', label: 'Stereo' }] },
    { role: 'notes', kind: 'text_box', label: 'Notes' },
    { role: 'record', kind: 'button', label: 'Record control check' },
  ] },
  scope: 'Hardware check — local values only', locked: false,
  values: { name: 'Vive check', mode: 'hold', enabled: 'true', gain: '20', phase: '0', channels: '[left]', notes: '' },
  enabled: { record: true },
  edit(role, value) {
    report.edits.push({ role, value })
    model.values[role] = value
    world.setWorkspace(model)
  },
  invoke(role) {
    if (role === 'record') {
      report.submissions.push({ ...model.values })
      status.textContent = `Recorded control check ${report.submissions.length}.`
    }
  },
  close() { world.setWorkspace(null) },
}
document.querySelector('#show').onclick = () => world.setWorkspace(model)
document.querySelector('#enter').onclick = () => world.immersive().catch(error => {
  report.errors.push(String(error)); status.textContent = String(error)
})
window.addEventListener('error', event => report.errors.push(event.message))
window.addEventListener('unhandledrejection', event => report.errors.push(String(event.reason)))
window.addEventListener('pagehide', () => world.dispose(), { once: true })
window.guiHardwareReport = () => structuredClone(report)
window.guiHardwareOpacity = value => {
  const texture = EngineStore.LastCreatedScene.getMeshByName('workspace')?.material.emissiveTexture
  if (!texture) throw new Error('Headset panel is not installed')
  texture.getControlByName('workspace-opacity').value = value
}
world.setWorkspace(model)
