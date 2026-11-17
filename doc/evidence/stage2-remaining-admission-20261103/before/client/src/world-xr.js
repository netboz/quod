import { WebXRState } from '@babylonjs/core/XR/webXRTypes.js'

const deferred = () => {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return { promise, resolve }
}

// Part of the world owner. Babylon retains the session/camera/input/layer;
// this scope joins their asynchronous entry and termination before disposal.
export function createWorldXR(scene, { connect, disconnect, cancel, changed, error }) {
  let experience = null, preparing = null, attempt = null, disposed = false
  let state = 'preparing', disposal = null
  const publish = next => { state = next; changed(next, experience) }
  const report = cause => error(cause instanceof Error ? cause : new Error(String(cause)))

  function guard(callback, retiring = false) {
    return (...args) => {
      if (!retiring && (disposed || attempt?.stopped)) return
      try { return callback(...args) } catch (cause) { fail(cause) }
    }
  }
  function fail(cause) {
    report(cause)
    if (attempt) {
      attempt.failed = true
      void stop(attempt).catch(report)
    }
  }
  function release() {
    if (!experience) return
    disconnect()
    const current = experience
    experience = null
    current.input?.dispose()
    current.renderTarget?.dispose()
    current.baseExperience.featuresManager.dispose()
    current.baseExperience.dispose()
  }
  function prepare() {
    if (disposed) return Promise.resolve()
    if (preparing) return preparing
    if (experience) return Promise.resolve()
    publish('preparing')
    preparing = (async () => {
      const [{ WebXRExperienceHelper }, { WebXRInput }] = await Promise.all([
        import('@babylonjs/core/XR/webXRExperienceHelper.js'),
        import('@babylonjs/core/XR/webXRInput.js'),
        import('@babylonjs/core/XR/motionController/webXRHTCViveMotionController.js'),
      ])
      if (disposed) return
      const baseExperience = await WebXRExperienceHelper.CreateAsync(scene)
      experience = { baseExperience, input: null, renderTarget: null }
      if (disposed) { release(); return }
      const manager = baseExperience.sessionManager
      // The pinned manager installs its native end handler before this notice.
      manager.onXRSessionInit.add(session => {
        const current = attempt
        if (!current) throw new Error('XR session has no world entry owner.')
        capture(current, session)
      }, undefined, true)
      manager.onXRSessionEnded.add(() => {
        if (attempt) ended(attempt)
      }, undefined, true)
      baseExperience.onStateChangedObservable.add(guard(value => {
        if (value === WebXRState.IN_XR && attempt && !attempt.stopped) {
          attempt.presenting = true
          publish('presenting')
        }
      }))
      experience.input = new WebXRInput(manager, baseExperience.camera, {
        disableOnlineControllerRepository: true, doNotLoadControllerMeshes: true,
      })
      experience.renderTarget = manager.getWebXRRenderTarget()
      connect(experience)
      publish('ready')
    })().catch(cause => {
      release()
      if (!disposed) publish('unavailable')
      throw cause
    }).finally(() => { preparing = null })
    return preparing
  }
  function capture(current, session) {
    if (current.session === session) return
    if (current.session) throw new Error('XR entry acquired more than one session.')
    current.session = session
    current.onEnd = () => ended(current)
    session.addEventListener('end', current.onEnd, { once: true })
    if (current.stopped) void requestEnd(current).catch(report)
  }
  function ended(current) {
    current.ended = true
    current.nativeEnd.resolve()
    // Let all native end listeners finish, including Babylon's render restore.
    void Promise.resolve().then(() => stop(current)).catch(report)
  }
  function requestEnd(current) {
    if (!current.session || current.ended) return Promise.resolve()
    if (!current.ending) {
      const ending = Promise.resolve().then(() => {
        if (!current.ended) return current.session.end()
      }).catch(cause => {
        if (!current.ended) throw new Error('VR release is unconfirmed. Use the headset or browser exit control.', { cause })
      })
      current.ending = Promise.race([ending, current.nativeEnd.promise])
      // Surface refusal even if an unrelated entry continuation is still
      // pending. Keep its dependencies alive until that continuation settles.
      void current.ending.catch(cause => {
        if (!current.ended && attempt === current) { publish('blocked'); report(cause) }
      })
    }
    return current.ending
  }
  function stop(current = attempt) {
    if (!current) return Promise.resolve()
    if (current.cleanup) return current.cleanup
    current.stopped = true
    cancel()
    publish('stopping')
    // Begin release now, even when an entry continuation is still pending.
    void requestEnd(current).catch(() => {})
    current.cleanup = (async () => {
      await current.entry.catch(() => {})
      const session = experience?.baseExperience.sessionManager.session
      if (!current.session && session && session !== current.previousSession) capture(current, session)
      await requestEnd(current)
      // A resolved end promise confirms release; its native end dispatch must
      // also complete before we remove listeners or destroy render dependencies.
      if (current.session) await current.nativeEnd.promise
      current.session?.removeEventListener('end', current.onEnd)
      const retire = disposed || current.failed || !current.presenting
      if (retire) {
        release()
        scene.autoClear = current.desktop.autoClear
        scene.activeCamera = current.desktop.camera
        if (current.desktop.attached) current.desktop.camera.attachControl(current.desktop.noPreventDefault)
      }
      if (attempt === current) attempt = null
      current.finished.resolve()
      if (!disposed) {
        if (retire) await prepare()
        else publish('ready')
      }
    })().catch(cause => {
      if (attempt === current) publish('blocked')
      current.cleanup = null
      throw cause
    })
    return current.cleanup
  }
  function enter() {
    if (disposed || state !== 'ready' || attempt) return Promise.reject(new Error('VR is not ready to enter.'))
    const camera = scene.activeCamera
    const current = { session: null, previousSession: experience.baseExperience.sessionManager.session,
      nativeEnd: deferred(), finished: deferred(), stopped: false, presenting: false, failed: false,
      desktop: { camera, autoClear: scene.autoClear, attached: Boolean(camera?.inputs?.attachedToElement),
        noPreventDefault: camera?.inputs?.noPreventDefault } }
    attempt = current
    cancel()
    publish('starting')
    // No network/import preparation between the click and this request path.
    current.entry = experience.baseExperience.enterXRAsync('immersive-vr', 'local-floor', experience.renderTarget)
    return current.entry.catch(async cause => {
      current.failed = true
      try { await stop(current) } catch (cleanupError) { report(cleanupError) }
      throw cause
    })
  }
  function dispose() {
    if (disposal) return disposal
    disposed = true
    cancel()
    disconnect()
    disposal = (async () => {
      const current = attempt
      if (current) {
        try { await stop(current) } catch (cause) { report(cause); await current.finished.promise }
      }
      await preparing?.catch(report)
      release()
      publish('disposed')
    })()
    return disposal
  }
  return { prepare, enter, exit: stop, dispose, guard, fail,
    get state() { return state }, get experience() { return experience } }
}
