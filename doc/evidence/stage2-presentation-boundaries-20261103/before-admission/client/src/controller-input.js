// Interprets the installed Prolog descriptor. Existing XR objects own all
// observations; this owner retains only captures, associations and rearming.
export function createControllerInput({ navigation, pointer, menu, blocked = () => false,
  appearance = () => {}, retireAppearance = () => {}, changed = () => {}, guard = fn => fn }) {
  const sources = new Map(), choices = new Map()
  let mapping = null, menuOwner = null, pointerOwner = null, nextId = 1
  const neutral = c => !c?.pressed && (!c?.axes || Math.hypot(c.axes.x, c.axes.y) < 0.01)
  function cancel(source) {
    if (pointerOwner === source) { pointer.cancel(source.id); pointerOwner = null }
    if (menuOwner === source) { menu.cancel(); menuOwner = null }
    if (source.bindings.some(b => b.action === 'drive')) navigation.axes({ x: 0, y: 0 })
    for (const b of source.bindings) { b.armed = false; b.down = false }
  }
  function cancelAll() { for (const source of sources.values()) cancel(source) }
  function cancelMenu() {
    if (!menuOwner) return
    const source = menuOwner
    if (pointerOwner === source) { pointer.cancel(source.id); pointerOwner = null }
    for (const b of source.bindings) if (b.action === 'menu' || b.action === 'select') b.armed = false
    menuOwner = null; menu.cancel()
  }
  function stopNavigation() {
    for (const source of sources.values()) for (const b of source.bindings) {
      if (b.action === 'drive') navigation.axes({ x: 0, y: 0 })
      if (['drive', 'snap', 'teleport'].includes(b.action)) b.armed = false
    }
  }
  function resolve() {
    for (const source of sources.values()) if (source.hand !== source.controller.inputSource.handedness) {
      for (const [role, selected] of choices) if (selected === source) choices.delete(role)
    }
    const roles = new Map(Object.entries(mapping?.roles ?? {}).map(([role, hand]) => {
      const candidates = [...sources.values()].filter(s => s.controller.inputSource.handedness === hand)
      return [role, choices.get(role) ?? (candidates.length === 1 ? candidates[0] : null)]
    }))
    const conflict = roles.get('navigation') && roles.get('navigation') === roles.get('menu')
    for (const source of sources.values()) {
      const input = source.controller.inputSource
      const changedHand = source.hand !== input.handedness
      source.hand = input.handedness
      source.motion = source.controller.motionController
      const previous = source.bindings
      source.bindings = []
      source.reason = 'Controller descriptions unavailable.'
      const profiles = mapping?.profiles.filter(p => input.profiles.some(name => p.names.includes(name))) ?? []
      source.profile = profiles.length === 1 && !input.hand ? profiles[0] : null
      appearance(source.controller, source.profile)
      if (!source.profile || !source.motion) {
        source.reason = input.hand ? 'Bare-hand input is not supported.' : 'Waiting for supported controller components.'
        const next = source.bindings; source.bindings = previous; cancel(source); source.bindings = next
        continue
      }
      source.reason = ''
      const components = new Map(source.profile.components.map(described => {
        const component = source.motion.getComponent(described.id)
        // A named component must actually provide its described facilities.
        const usable = component && component.type === described.type &&
          (!described.features.includes('press') || component.isButton()) &&
          (!described.features.includes('axes2') || component.isAxes())
        return [described.name, usable ? component : null]
      }))
      for (const binding of mapping.bindings) {
        if (binding.role !== 'any') {
          const selected = roles.get(binding.role)
          if (conflict && selected === source) {
            source.reason = 'Movement and menu resolve to the same controller. Choose distinct controllers.'
            continue
          }
          if (selected !== source) {
            if (!selected && source.hand === mapping.roles[binding.role]) source.reason = 'Several controllers match this hand. Choose one for this session.'
            continue
          }
        }
        const component = components.get(binding.component), modifier = binding.modifier && components.get(binding.modifier)
        if (!component || binding.modifier && !modifier) {
          source.reason = `Some bindings need a missing ${!component ? binding.component : binding.modifier}.`; continue
        }
        source.bindings.push({ ...binding, component, modifier, armed: false, down: false })
      }
      const same = !changedHand && source.digest === mapping?.digest && previous.length === source.bindings.length &&
        previous.every((b, i) => b.id === source.bindings[i].id && b.component === source.bindings[i].component && b.modifier === source.bindings[i].modifier)
      if (same) source.bindings = previous
      else { const next = source.bindings; source.bindings = previous; cancel(source); source.bindings = next }
      source.digest = mapping?.digest
    }
    changed()
  }
  function add(controller) {
    if (sources.has(controller)) return
    const source = { controller, id: nextId++, bindings: [], tracked: false, reason: '' }
    sources.set(controller, source)
    source.observer = controller.onMotionControllerInitObservable.add(guard(() => {
      if (sources.get(controller) === source) resolve()
    }))
    resolve()
  }
  function remove(controller) {
    const source = sources.get(controller)
    if (!source) return
    cancel(source)
    pointer.hide(source.id)
    controller.onMotionControllerInitObservable.remove(source.observer)
    sources.delete(controller)
    for (const [role, selected] of choices) if (selected === source) choices.delete(role)
    retireAppearance(controller)
    resolve()
  }
  function frame(validPose, active = true) {
    if ([...sources.values()].some(s => s.hand !== s.controller.inputSource.handedness || s.motion !== s.controller.motionController)) resolve()
    for (const source of sources.values()) {
      const tracked = active && mapping && validPose(source.controller)
      if (!tracked) {
        if (source.tracked) { cancel(source); source.tracked = false; changed() }
        pointer.hide(source.id)
        continue
      }
      if (!source.tracked) { source.tracked = true; changed() }
      const canPoint = source.bindings.some(b => b.action === 'select') && (!pointerOwner || pointerOwner === source)
      if (canPoint) pointer.move(source.controller, source.id, menuOwner ? 'menu' : blocked() ? 'workspace' : 'world')
      else pointer.hide(source.id)
      for (const b of source.bindings) {
        const pressed = Boolean(b.component.pressed), axes = b.component.axes
        const suppressed = b.action !== 'select' && (blocked() || menuOwner && menuOwner !== source || pointerOwner && !(b.action === 'menu' && menuOwner === source && pointerOwner === source))
        if (suppressed) {
          if (b.action === 'drive') navigation.axes({ x: 0, y: 0 })
          b.armed = false; b.down = pressed; continue
        }
        if (!b.armed) {
          b.armed = neutral(b.component) && (!b.modifier || neutral(b.modifier))
          b.down = pressed; b.modifierDown = Boolean(b.modifier?.pressed); continue
        }
        const down = pressed && !b.down, up = !pressed && b.down
        if (b.down && b.modifier && b.modifierDown !== Boolean(b.modifier.pressed)) {
          b.armed = false
          if (b.action === 'drive') navigation.axes({ x: 0, y: 0 })
        }
        b.modifierDown = Boolean(b.modifier?.pressed)
        b.down = pressed
        if (!b.armed) continue
        if (b.kind === 'press_release') {
          if (down && !pointerOwner && (!menuOwner || menuOwner === source)) {
            pointerOwner = source; stopNavigation(); pointer.down(source.controller, source.id)
          }
          if (up && pointerOwner === source) {
            pointerOwner = null
            pointer.up(source.controller, source.id)
          }
        } else if (b.kind === 'radial') {
          if (down && !menuOwner && menu.open(axes, b.threshold)) {
            menuOwner = source
            for (const other of sources.values()) for (const move of other.bindings) {
              if (move.action === 'drive') navigation.axes({ x: 0, y: 0 })
              if (move.action !== 'select' && move !== b) move.armed = false
            }
          }
          if (menuOwner === source) {
            menu.move(axes, b.threshold)
            if (up) { menuOwner = null; menu.commit() }
          }
        } else if (b.kind === 'axes_while') {
          navigation.axes(!menuOwner && b.modifier.pressed ? axes : { x: 0, y: 0 })
        } else if (b.kind === 'sector' && down && !b.modifier.pressed && !menuOwner) {
          if (b.sector === 'horizontal' && Math.abs(axes.x) > b.threshold && Math.abs(axes.x) > Math.abs(axes.y)) navigation.snap(axes.x)
          else if (b.sector === 'forward' && axes.y < -b.threshold && Math.abs(axes.y) >= Math.abs(axes.x)) navigation.teleport(source.controller, b.fraction)
        }
      }
    }
  }
  return {
    add, remove, frame, cancel: cancelAll, cancelMenu,
    install(next) {
      if (mapping?.digest === next?.digest) return
      mapping = next; choices.clear(); resolve()
    },
    menuSelected() {
      if (!menuOwner) return
      for (const b of menuOwner.bindings) if (b.action === 'menu') b.armed = false
      menuOwner = null
    },
    choose(role, id) {
      if (!mapping || !Object.hasOwn(mapping.roles, role)) return
      const source = [...sources.values()].find(s => String(s.id) === id)
      if (source) {
        const other = role === 'navigation' ? 'menu' : 'navigation'
        const selected = choices.get(other)
        const candidates = [...sources.values()].filter(s => s.controller.inputSource.handedness === mapping.roles[other])
        if ((selected ?? (candidates.length === 1 ? candidates[0] : null)) === source) return false
        choices.set(role, source)
      } else if (id === '') choices.delete(role); else return false
      resolve(); return true
    },
    get status() {
      return { available: Boolean(mapping), choices: Object.fromEntries([...choices].map(([r,s]) => [r,String(s.id)])),
        sources: [...sources.values()].map(s => ({ id: String(s.id), hand: s.controller.inputSource.handedness,
          profile: s.profile?.class ?? 'unsupported', tracked: s.tracked,
          bindings: s.bindings.map(b => b.id), reason: s.reason })) }
    },
    dispose() { for (const controller of sources.keys()) remove(controller) },
  }
}
