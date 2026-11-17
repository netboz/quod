// Bounded transport observation; never emit headers, signatures, bodies or keys.
const dc = require('node:diagnostics_channel')
if (!process.argv.some(value => value.endsWith('/ontology-acl.acceptance.mjs'))) return
const fs = require('node:fs')
const start = performance.now(), sockets = new WeakMap(), requests = new WeakMap()
const rows = []
let socketCount = 0, requestCount = 0
const now = () => Math.round(performance.now() - start)
const emit = row => {
  const record = { ms: now(), utc_ms: Date.now(), ...row }
  if (rows.length < 2048) rows.push(record)
  if (!process.env.M0_HTTP_DIAGNOSTIC_DIRECTORY || ['error', 'fault_injected_event_loop_stall'].includes(row.event)) {
    process.stdout.write('M0_HTTP ' + JSON.stringify(record) + '\n')
  }
}
dc.channel('undici:client:sendHeaders').subscribe(({ request, socket }) => {
  if (!sockets.has(socket)) {
    const id = ++socketCount
    sockets.set(socket, id)
    socket.on('end', () => emit({ event: 'socket_end', socket: id }))
    socket.on('close', hadError => emit({ event: 'socket_close', socket: id, hadError }))
  }
  const path = request.path.split('?')[0].replace(/(\/api\/goals\/cursors)\/[^/]+/, '$1/:id')
  const row = { request: ++requestCount, socket: sockets.get(socket), method: request.method,
    path, bytes: request.contentLength, start: now(), written: socket.bytesWritten, read: socket.bytesRead }
  requests.set(request, row)
  if (requestCount <= 512) emit({ event: 'send', ...row })
})
dc.channel('undici:request:headers').subscribe(({ request, response }) => {
  const row = requests.get(request)
  if (row?.request <= 512) emit({ event: 'response', ...row, elapsed: now() - row.start, status: response.statusCode })
})
dc.channel('undici:request:error').subscribe(({ request, error }) => {
  emit({ event: 'error', ...requests.get(request), written: error.socket?.bytesWritten,
    read: error.socket?.bytesRead, code: error.code, name: error.name })
})
const originalFetch = globalThis.fetch
let responseCount = 0
globalThis.fetch = async (...args) => {
  const response = await originalFetch(...args)
  const json = response.json.bind(response)
  response.json = async () => {
    const value = await json()
    const number = ++responseCount
    if (number === Number(process.env.M0_BLOCK_RESPONSE)) {
      emit({ event: 'fault_injected_event_loop_stall', response: number, milliseconds: 5100 })
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5100)
    }
    return value
  }
  return response
}
process.on('exit', code => {
  emit({ event: 'exit', code, requestCount, socketCount })
  if (process.env.M0_HTTP_DIAGNOSTIC_DIRECTORY) {
    fs.writeFileSync(`${process.env.M0_HTTP_DIAGNOSTIC_DIRECTORY}/m0-acl-transport-${process.pid}.json`,
      JSON.stringify(rows, null, 2) + '\n', { mode: 0o600, flag: 'wx' })
  }
})
