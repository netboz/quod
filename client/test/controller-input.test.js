import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Observable } from '@babylonjs/core/Misc/observable.js'
import { WebXRControllerComponent } from '@babylonjs/core/XR/motionController/webXRControllerComponent.js'
import { createControllerInput } from '../src/controller-input.js'

const profile = { class: 'vive', names: ['htc-vive'], components: [
  { name: 'trigger', id: 'trigger', type: 'trigger', features: ['press'] },
  { name: 'grip', id: 'grip', type: 'squeeze', features: ['press'] },
  { name: 'pad', id: 'pad', type: 'touchpad', features: ['press', 'axes2'] },
] }
const mapping = { digest: 'first', roles: { navigation: 'left', menu: 'right' }, profiles: [profile], bindings: [
  { id: 'select', role: 'any', component: 'trigger', kind: 'press_release', action: 'select' },
  { id: 'menu', role: 'menu', component: 'pad', kind: 'radial', action: 'menu', threshold: .24 },
  { id: 'drive', role: 'navigation', component: 'pad', kind: 'axes_while', modifier: 'grip', action: 'drive' },
  { id: 'snap', role: 'navigation', component: 'pad', kind: 'sector', modifier: 'grip', sector: 'horizontal', threshold: .5, action: 'snap' },
  { id: 'teleport', role: 'navigation', component: 'pad', kind: 'sector', modifier: 'grip', sector: 'forward', threshold: .5, fraction: .5, action: 'teleport' },
] }
function wand(hand) {
  const components = { trigger: new WebXRControllerComponent('trigger', 'trigger', 0),
    grip: new WebXRControllerComponent('grip', 'squeeze', 0),
    pad: new WebXRControllerComponent('pad', 'touchpad', 0, [0, 1]) }
  return { inputSource: { handedness: hand, profiles: ['htc-vive'] },
    onMotionControllerInitObservable: new Observable(), motionController: { getComponent: name => components[name] }, components,
    button(name, pressed, x = 0, y = 0) {
      components[name].update({ buttons: [{ pressed, touched: pressed, value: Number(pressed) }], axes: [x, y] })
    } }
}
function setup(reverse = false) {
  const events = [], state = { blocked: false, tracked: true }
  const input = createControllerInput({ navigation: {
    axes: v => events.push(['drive', v.x, v.y]), snap: v => events.push(['snap', v]), teleport: (_, f) => events.push(['teleport', f]),
  }, pointer: { move() {}, hide() {}, down: (_, id) => events.push(['down', id]), up: (_, id) => events.push(['up', id]), cancel: id => events.push(['cancel', id]) },
  menu: { open: () => { events.push(['menu']); return true }, move() {}, commit: () => events.push(['commit']), cancel: () => events.push(['dismiss']) },
  blocked: () => state.blocked })
  input.install(mapping)
  const left = wand('left'), right = wand('right')
  for (const source of reverse ? [right, left] : [left, right]) input.add(source)
  const frame = () => input.frame(() => state.tracked)
  frame(); events.length = 0
  return { input, left, right, frame, events, state }
}
test('real Babylon component observations drive one permitted semantic request per edge', () => {
  const f = setup()
  f.left.button('pad', true, .8, 0); f.frame(); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'snap').length, 1)
  f.left.button('pad', false); f.frame()
  f.left.button('grip', true); f.left.button('pad', true, 0, -.8); f.frame()
  assert.ok(f.events.some(e => e[0] === 'drive' && e[2] === -.8))
  assert.equal(f.events.filter(e => e[0] === 'teleport').length, 0)
})
test('tracking loss cancels a pressed selection and a menu without activation; held recovery rearms only after release', () => {
  const f = setup()
  f.right.button('pad', true); f.frame()
  f.right.button('trigger', true); f.frame()
  f.state.tracked = false; f.frame()
  assert.ok(f.events.some(e => e[0] === 'cancel'))
  assert.ok(f.events.some(e => e[0] === 'dismiss'))
  f.state.tracked = true; f.frame()
  f.right.button('trigger', false); f.right.button('pad', false); f.frame()
  assert.equal(f.events.filter(e => ['commit', 'up'].includes(e[0])).length, 0)
  f.right.button('trigger', true); f.frame(); f.right.button('trigger', false); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'up').length, 1)
})
test('unchanged renewal and unrelated disconnect preserve held navigation; a changed mapping retires it', () => {
  const f = setup()
  f.left.button('grip', true); f.left.button('pad', false, 0, -.7); f.frame()
  f.events.length = 0
  f.input.install({ ...mapping }); f.input.remove(f.right); f.frame()
  assert.ok(f.events.every(e => e[0] !== 'drive' || e[2] === -.7))
  f.input.install({ ...mapping, digest: 'second', roles: { navigation: 'right', menu: 'left' } }); f.frame()
  assert.equal(f.events.at(-1)[0], 'drive')
  assert.equal(f.events.at(-1)[2], 0)
})
test('unknown handedness never becomes the menu; duplicate hands disable roles without disabling selection', () => {
  const f = setup(), extra = wand('left'), unknown = wand('none')
  f.input.add(extra); f.input.add(unknown); f.frame()
  f.events.length = 0
  f.left.button('pad', true, .8, 0); unknown.button('pad', true); f.frame()
  assert.equal(f.events.filter(e => ['menu', 'snap'].includes(e[0])).length, 0)
  unknown.button('trigger', true); f.frame(); unknown.button('trigger', false); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'up').length, 1)
  f.input.choose('navigation', '1'); f.left.button('pad', false); f.frame()
  f.left.button('pad', true, .8, 0); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'snap').length, 1)
})
test('menu selection consumes radial release, and closing a workspace does not resume held travel', () => {
  const f = setup()
  f.right.button('pad', true); f.frame(); f.input.menuSelected()
  f.right.button('pad', false); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'commit').length, 0)
  f.state.blocked = true; f.frame()
  f.left.button('grip', true); f.left.button('pad', false, 0, -1)
  f.state.blocked = false; f.events.length = 0; f.frame()
  assert.equal(f.events.filter(e => e[0] === 'drive' && e[2] !== 0).length, 0)
})
test('late initialization after removal and missing axes cannot resurrect a binding', () => {
  const f = setup(), source = wand('none')
  source.motionController = null; f.input.add(source); f.input.remove(source)
  source.onMotionControllerInitObservable.notifyObservers({})
  assert.equal(f.input.status.sources.length, 2)
  const missing = wand('right')
  missing.components.pad = new WebXRControllerComponent('pad', 'touchpad', 0)
  f.input.remove(f.right); f.input.add(missing); f.frame()
  assert.deepEqual(f.input.status.sources.at(-1).bindings, ['select'])
})

test('changing the modifier while the pad is held cannot turn a snap into travel', () => {
  const f = setup()
  f.left.button('pad', true, .8, 0); f.frame()
  f.left.button('grip', true); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'snap').length, 1)
  assert.equal(f.events.filter(e => e[0] === 'drive' && e[1] !== 0).length, 0)
  f.left.button('pad', false); f.left.button('grip', false); f.frame()
  f.left.button('grip', true); f.left.button('pad', true, .8, 0); f.frame()
  assert.ok(f.events.some(e => e[0] === 'drive' && e[1] === .8))
})

test('loss of a temporary choice never routes menu and movement to the same remaining source', () => {
  const f = setup(), extra = wand('left')
  f.input.add(extra)
  assert.equal(f.input.choose('menu', '1'), true)
  f.input.remove(extra); f.frame()
  f.events.length = 0
  f.left.button('pad', true, .8, 0); f.frame()
  assert.equal(f.events.filter(e => ['menu', 'snap'].includes(e[0])).length, 0)
  assert.match(f.input.status.sources[0].reason, /same controller/)
  f.input.choose('menu', ''); f.left.button('pad', false); f.frame()
  f.left.button('pad', true, .8, 0); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'snap').length, 1)
})

test('mapping withdrawal and owner cancellation retire captures without activation', () => {
  const f = setup()
  f.left.button('trigger', true); f.frame()
  f.input.install(null); f.left.button('trigger', false); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'cancel').length, 1)
  assert.equal(f.events.filter(e => e[0] === 'up').length, 0)
  f.input.install(mapping); f.frame()
  f.left.button('trigger', true); f.frame(); f.input.cancel()
  f.left.button('trigger', false); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'cancel').length, 2)
  assert.equal(f.events.filter(e => e[0] === 'up').length, 0)
})

for (const reverse of [false, true]) test(`pointer capture stops travel in the same frame, reverse sources=${reverse}`, () => {
  const f = setup(reverse)
  f.left.button('grip', true); f.left.button('pad', false, 0, -.7); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'drive').at(-1)[2], -.7)
  f.right.button('trigger', true); f.events.length = 0; f.frame()
  assert.equal(f.events.filter(e => e[0] === 'drive').at(-1)[2], 0)
  f.right.button('trigger', false); f.frame(); f.events.length = 0; f.frame()
  assert.ok(f.events.every(e => e[0] !== 'drive' || e[2] === 0))
  f.left.button('grip', false); f.left.button('pad', false); f.frame()
  f.left.button('grip', true); f.left.button('pad', false, 0, -.7); f.frame()
  assert.equal(f.events.filter(e => e[0] === 'drive').at(-1)[2], -.7)
})

test('changing menu entries retires only an active menu gesture and its selection', () => {
  const f = setup()
  f.left.button('grip', true); f.left.button('pad', false, 0, -.7); f.frame()
  f.input.cancelMenu(); f.events.length = 0; f.frame()
  assert.equal(f.events.filter(e => e[0] === 'drive').at(-1)[2], -.7)
  f.right.button('pad', true); f.frame(); f.right.button('trigger', true); f.frame()
  f.input.cancelMenu()
  assert.ok(f.events.some(e => e[0] === 'cancel'))
  assert.ok(f.events.some(e => e[0] === 'dismiss'))
  f.right.button('pad', false); f.right.button('trigger', false); f.frame()
  assert.equal(f.events.filter(e => ['commit', 'up'].includes(e[0])).length, 0)
})
