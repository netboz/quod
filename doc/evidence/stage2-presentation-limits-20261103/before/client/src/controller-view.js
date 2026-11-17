import { readTerm, requireProjection } from './prolog-read.js'
import { compound, variable } from './prolog-term.js'
import { anchoredGoal, guiDigest } from './world.js'
import { connectSignedView, readViewIdentity } from './signed-view.js'
import { fromB64url } from './key-provider.js'

const fail = () => { throw new Error('Invalid controller description.') }
const args = (t, name, n) => t?.type === 'compound' && t.functor === name && t.args.length === n ? t.args : fail()
const atom = t => t?.type === 'atom' ? t.value : fail()
const integer = t => t?.type === 'number' && Number.isSafeInteger(t.value) ? t.value : fail()
const list = t => t?.type === 'list' && t.tail === null ? t.items : fail()
const text = t => t?.type === 'binary' ? new TextDecoder('utf-8', { fatal: true }).decode(t.value) : fail()
const unique = (rows, key) => new Set(rows.map(key)).size === rows.length ? rows : fail()

export function readControllerView(value) {
  const term = readTerm(value); requireProjection(term)
  const [revision, digest, mapping] = args(term, 'controller_view', 3)
  if (integer(revision) < 0) fail()
  const parsedDigest = guiDigest(digest)
  // This is an authorized disabled state: keep the signed subscription so an
  // explicit repair can publish a fresh mapping through the ordinary owner.
  if (mapping.type === 'atom' && mapping.value === 'invalid_settings') return null
  const [version, roles, bindings, profiles] = args(mapping, 'mapping', 4)
  if (integer(version) !== 1) fail()
  const result = { revision: integer(revision), digest: parsedDigest,
    roles: Object.fromEntries(unique(list(roles).map(row => {
      const [role, selector] = args(row, 'role', 2)
      return [atom(role), atom(args(selector, 'hand', 1)[0])]
    }), row => row[0])),
    bindings: unique(list(bindings).map(row => {
      const [id, role, component, gesture, output] = args(row, 'bind', 5)
      const kind = gesture.type === 'atom' ? atom(gesture) : gesture.functor
      let threshold, modifier, sector
      if (kind === 'radial') threshold = integer(args(gesture, kind, 1)[0]) / 1000
      else if (kind === 'axes_while') modifier = atom(args(gesture, kind, 1)[0])
      else if (kind === 'sector') {
        const [s, t, m] = args(gesture, kind, 3); sector = atom(s); threshold = integer(t) / 1000; modifier = atom(m)
        if (!['horizontal', 'forward'].includes(sector)) fail()
      } else if (kind !== 'press_release') fail()
      if (threshold !== undefined && !(threshold > 0 && threshold < 1)) fail()
      const [action] = args(output, output.functor, 1)
      if (!['local', 'control'].includes(output.functor)) fail()
      const name = action.type === 'atom' ? atom(action) : action.functor
      let fraction
      if (name === 'teleport') fraction = integer(args(action, 'teleport', 1)[0]) / 1000
      if (!['select', 'menu', 'drive', 'snap', 'teleport'].includes(name) ||
          (fraction !== undefined && !(fraction > 0 && fraction < 1))) fail()
      if (name === 'drive' && !['navigation', 'menu'].includes(atom(role))) fail()
      return { id: atom(id), role: atom(role), component: atom(component), kind, threshold, modifier, sector, action: name, fraction }
    }), row => row.id),
    profiles: unique(list(profiles).map(row => {
      const [classTerm, description] = args(row, 'profile', 2)
      const [names, components, poses, appearance] = args(description, 'controller', 4)
      const [attachment, asset] = args(appearance, 'tracked_model', 2)
      const [hash, format, bounds, costs] = args(asset, 'asset', 4)
      const model = { digest: text(hash), profile: text(format), bounds: args(bounds, 'bounds', 6).map(integer),
        allowed: args(costs, 'resources', 7).map(integer), scale: 1, pivot: [0, 0, 0], front: '-z' }
      if (!/^[a-f0-9]{64}$/.test(model.digest) || model.profile !== 'gltf2-static-v1' ||
          model.allowed.some(n => n < 0) || atom(attachment) !== 'grip') fail()
      return { class: atom(classTerm), names: list(names).map(text), poses: list(poses).map(atom), model,
        components: unique(list(components).map(c => {
          const [name, id, type, features] = args(c, 'component', 4)
          return { name: atom(name), id: text(id), type: atom(type), features: list(features).map(atom) }
        }), c => c.name) }
    }), row => row.class) }
  if (!['left', 'right', 'none'].includes(result.roles.navigation) ||
      !['left', 'right', 'none'].includes(result.roles.menu)) fail()
  return result
}

export function connectControllerView(identity, human, callbacks, options = {}) {
  const reference = { namespace: human.namespace,
    anchor: typeof human.anchor === 'string' ? fromB64url(human.anchor) : human.anchor }
  const goal = compound('controller_preferences_view', [readTerm(human.instanceText.replace(/\.\s*$/, '')), variable('View')])
  return connectSignedView(identity, human, reference, 'controller_preferences', anchoredGoal(reference, goal), {
    decode(message) {
      if (message.kind !== 'controller_preferences') fail()
      return { ...readViewIdentity(message), mapping: readControllerView(message.value) }
    },
  }, { ...callbacks, projection: current => callbacks.projection(current.mapping) }, options)
}
