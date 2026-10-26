import { test } from 'node:test'
import assert from 'node:assert/strict'
import { controllerPanel } from '../src/controller-panel.js'

test('tracking status and failed role choices update values without replacing the panel schema', () => {
  const status = { available: true, sources: [{ id: '1', hand: 'left', profile: 'vive', tracked: true, bindings: ['select'], reason: '' }], choices: {} }
  const panel = controllerPanel(() => ({ controllerStatus: () => status, chooseController: () => false }), { close() {}, settings() {} })
  const before = panel.current
  status.sources[0].tracked = false
  const lost = panel.current
  assert.deepEqual(lost.view, before.view)
  assert.notEqual(lost.values['source:1'], before.values['source:1'])
  lost.edit('menu', '1')
  assert.deepEqual(panel.current.view, before.view)
  assert.match(panel.current.values['connection-status'], /distinct controllers/)
})
