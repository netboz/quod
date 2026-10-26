// Bounded observations of the real browser/session. No permission override,
// simulated source, additional frame loop, request-body capture or auto-entry.
(() => {
  const state = { secure: isSecureContext, sessions: [], resources: [], csp: [], errors: [] }
  const retain = (rows, value, bound = 200) => { rows.push(value); if (rows.length > bound) rows.shift() }
  window.quodAcceptance = state
  addEventListener('securitypolicyviolation', e => retain(state.csp, {
    directive: e.effectiveDirective, blocked: e.blockedURI, disposition: e.disposition,
  }))
  addEventListener('error', e => retain(state.errors, { message: e.message, source: e.filename, line: e.lineno }))
  addEventListener('unhandledrejection', e => retain(state.errors, { rejection: String(e.reason) }))
  new PerformanceObserver(list => {
    for (const r of list.getEntries()) {
      const url = new URL(r.name, location.href)
      retain(state.resources, { origin: url.origin, path: url.pathname, type: r.initiatorType, bytes: r.transferSize })
    }
  }).observe({ type: 'resource', buffered: true })
  if (!navigator.xr) return
  const request = navigator.xr.requestSession.bind(navigator.xr)
  const viewportValue = (session, view) => {
    const v = session.renderState.baseLayer?.getViewport(view)
    return v ? { x: v.x, y: v.y, width: v.width, height: v.height } : null
  }
  const poseValue = pose => pose ? {
    position: [pose.transform.position.x, pose.transform.position.y, pose.transform.position.z],
    orientation: [pose.transform.orientation.x, pose.transform.orientation.y, pose.transform.orientation.z, pose.transform.orientation.w],
  } : null
  navigator.xr.requestSession = async function(mode, options) {
    const row = { mode, options, requested: Date.now(), frames: 0, stereoFrames: 0, trackedFrames: 0, references: [], samples: [], endCalls: 0 }
    retain(state.sessions, row, 10)
    let session
    try { session = await request(mode, options) }
    catch (error) { row.error = { name: error.name, message: error.message }; throw error }
    row.started = Date.now(); window.quodAcceptanceSession = session
    session.addEventListener('end', () => { row.ended = Date.now(); window.quodAcceptanceSession = null })
    session.addEventListener('visibilitychange', () => { row.visibility = session.visibilityState })
    const end = session.end.bind(session)
    session.end = (...args) => { row.endCalls++; return end(...args) }
    const space = session.requestReferenceSpace.bind(session)
    let reference
    session.requestReferenceSpace = async function(type) {
      const value = await space(type); row.references.push(type)
      if (type !== 'viewer') reference = value
      value.addEventListener('reset', () => { row.lastReferenceReset = Date.now() })
      return value
    }
    const raf = session.requestAnimationFrame.bind(session)
    session.requestAnimationFrame = callback => raf((time, frame) => {
      try {
        row.frames++
        if (reference) {
          const pose = frame.getViewerPose(reference)
          if (pose) { row.trackedFrames++; if (pose.views.length === 2) row.stereoFrames++ }
          if (row.frames % 60 === 1) retain(row.samples, {
            at: Date.now(), head: poseValue(pose), eyes: pose?.views.map(v => ({ eye: v.eye,
              viewport: viewportValue(session, v) })) ?? [],
            inputs: Array.from(session.inputSources, source => ({ handedness: source.handedness,
              profiles: Array.from(source.profiles), grip: source.gripSpace ? poseValue(frame.getPose(source.gripSpace, reference)) : null,
              ray: poseValue(frame.getPose(source.targetRaySpace, reference)), axes: Array.from(source.gamepad?.axes ?? []),
              buttons: source.gamepad?.buttons.map(b => ({ pressed: b.pressed, touched: b.touched, value: b.value })) ?? [],
            })),
          }, 120)
        }
      } catch (error) { row.measurementError = { name: error.name, message: error.message } }
      callback(time, frame)
    })
    return session
  }
})()

;
// Read-only bounded observations of existing signed view delivery.
(() => {
 const Native = WebSocket;
 window.quodViewDiagnosis = { frames: [], projections: [] };
 let first;window.quodFirstView=new Promise(resolve=>{first=resolve});
 window.WebSocket = new Proxy(Native, { construct(target,args,newTarget) {
  const socket = Reflect.construct(target,args,newTarget);
  let count=0;
  const observe = event => {
   const m = JSON.parse(event.data);
   if (!m.frame || m.frame.view_clearance === undefined) return;
   const f=m.frame, row={at:Date.now(),type:m.type,clearance:f.view_clearance,
    tick:f.tick,poses:f.poses,control:m.control??null};
   window.quodViewDiagnosis.frames.push(row);first(row);
   if(m.control)window.quodViewDiagnosis.projections.push(row);
   if(++count===12)socket.removeEventListener('message',observe);
  };
  socket.addEventListener('message',observe);
  return socket;
 }});
})();
