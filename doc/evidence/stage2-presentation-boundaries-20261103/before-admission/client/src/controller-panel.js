// Local connection choices share the existing workspace presentation contract.
// This panel never saves source identifiers or submits a domain operation.
export function controllerPanel(scene, { close, settings }) {
  const listeners = new Set()
  let choiceError = ''
  function model() {
    const status = scene()?.controllerStatus() ?? { available: false, sources: [], choices: {} }
    return { view: { title: 'VR controllers', fields: [
      { role: 'connection-status', kind: 'text_box', readonly: true, label: 'Connection' },
      ...status.sources.map(s => ({ role: `source:${s.id}`, kind: 'text_area', readonly: true, label: `Controller ${s.id}` })),
      ...['navigation', 'menu'].map(role => ({ role, kind: 'selection', label: role === 'navigation' ? 'Movement controller for this session' : 'Menu controller for this session',
        options: [{ value: '', label: 'Use saved hand preference' }, ...status.sources.map(s => ({ value: s.id, label: `${s.id}: ${s.hand} ${s.profile}` }))] })),
      { role: 'settings', kind: 'button', label: 'Edit saved bindings' },
      { role: 'close', kind: 'button', label: 'Close' },
    ] }, scope: '', values: { navigation: status.choices.navigation ?? '', menu: status.choices.menu ?? '',
      'connection-status': status.available ? choiceError || 'Temporary choices apply only to this connection.'
        : 'Controller settings are unavailable. Leave VR using the headset controls.',
      ...Object.fromEntries(status.sources.map(s => [`source:${s.id}`,
        `${s.profile}, ${s.hand}, ${s.tracked ? 'tracked' : 'not tracked'}; ${s.bindings.join(', ')}. ${s.reason}`])) },
    locked: false, enabled: { navigation: status.available, menu: status.available, settings: true, close: true },
    edit(role, value) {
      choiceError = scene()?.chooseController(role, value) === false ? 'Movement and menu need distinct controllers for these bindings.' : ''
      publish()
    },
    invoke(role) { if (role === 'settings') settings(); else if (role === 'close') close() }, close }
  }
  function publish() { for (const listener of listeners) listener(model()) }
  return { get current() { return model() }, refresh: publish,
    subscribe(listener) { listeners.add(listener); listener(model()); return () => listeners.delete(listener) } }
}
