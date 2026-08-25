#!/usr/bin/env node
// Fixed-work remote-proof benchmark using Quod's actual signed browser client.
// It deliberately imports the shared request encoder/authentication client: this
// harness owns endpoint selection and measurements, not a second goal protocol.

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { importEncryptedKeyProvider } from '../client/src/key-provider.js'
import { authenticateKey, postJson, signedGoal } from '../client/src/signed-client.js'

const defaults = {
  sourceEndpoints: '', sourceExplorerEndpoints: '', sourceNs: '', targetNs: '', goal: 'true', mode: 'read',
  requests: '1000', concurrency: '32', httpTimeout: '35', preflightTimeout: '60',
  maxFailures: '0', resultDir: '', agentAnchor: '', agentInstance: '',
  keyBundle: '', keyPassphraseEnv: '', insecureTls: false,
}

function die(message) { console.error(`cross-ontology-loadtest: ${message}`); process.exit(2) }
function usage() {
  console.log(`Usage: scripts/cross-ontology-loadtest.sh --source-endpoints URL[,URL...] \\
       --source-ns NAME --target-ns NAME [options]

Runs signed Target::Goal proofs through the browser client protocol. Every source
endpoint must host SOURCE_NS and must not co-host TARGET_NS; successful work
therefore necessarily crosses the authenticated directory/QUIC scope path.

Required:
  --source-endpoints URL[,URL...]  HTTPS client endpoint(s) hosting the source
  --source-explorer-endpoints URL[,URL...]
                                  matching Explorer endpoint(s) for preflight
  --source-ns NAME                 source ontology namespace
  --target-ns NAME                 remote target ontology namespace
  --agent-anchor HEX               source agent ontology genesis anchor
  --agent-instance TEXT            ground agent instance term
  --key-bundle PATH                encrypted browser-key export for that agent
  --key-passphrase-env NAME        environment variable holding its passphrase

Options:
  --goal TEXT                      target-local goal; __QUOD_REQUEST_ID__ is
                                   replaced with a unique atom for each request
  --mode read|execute              signed proof mode (default: read)
  --requests N                     exact number of remote proofs (default: 1000)
  --concurrency N                  maximum simultaneous remote proofs (default: 32)
  --http-timeout SEC               request deadline (default: 35)
  --preflight-timeout SEC          route/auth readiness wait (default: 60)
  --max-failures N                 fail above this many failed proofs (default: 0)
  --result-dir PATH                retain preflight/results TSV files
  --insecure-tls                   accept a development self-signed certificate
  --help                           show this help

An execute goal is submitted once. An uncertain result is recorded as failed;
the driver never re-proves or resubmits it. The benchmark never invents a
signing key: the configured key must already be active for the configured
agent instance in SOURCE_NS.`)
}

const opt = { ...defaults }
const names = new Map([
  ['--source-endpoints', 'sourceEndpoints'], ['--source-explorer-endpoints', 'sourceExplorerEndpoints'],
  ['--source-ns', 'sourceNs'],
  ['--target-ns', 'targetNs'], ['--goal', 'goal'], ['--mode', 'mode'],
  ['--requests', 'requests'], ['--concurrency', 'concurrency'],
  ['--http-timeout', 'httpTimeout'], ['--preflight-timeout', 'preflightTimeout'],
  ['--max-failures', 'maxFailures'], ['--result-dir', 'resultDir'],
  ['--agent-anchor', 'agentAnchor'], ['--agent-instance', 'agentInstance'],
  ['--key-bundle', 'keyBundle'], ['--key-passphrase-env', 'keyPassphraseEnv'],
])
for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i]
  if (arg === '--help' || arg === '-h') { usage(); process.exit(0) }
  if (arg === '--insecure-tls') { opt.insecureTls = true; continue }
  const [flag, inline] = arg.split('=', 2)
  const key = names.get(flag)
  if (!key) die(`unknown option: ${arg}`)
  const value = inline ?? process.argv[++i]
  if (value === undefined) die(`missing value for ${flag}`)
  opt[key] = value
}

function uint(name, value, positive = false) {
  if (!/^\d+$/.test(value) || (positive && Number(value) < 1)) die(`${name} must be ${positive ? 'positive' : 'a non-negative'} integer`)
  return Number(value)
}
const requests = uint('requests', opt.requests, true)
const concurrency = uint('concurrency', opt.concurrency, true)
const httpTimeout = uint('http-timeout', opt.httpTimeout, true)
const preflightTimeout = uint('preflight-timeout', opt.preflightTimeout)
const maxFailures = uint('max-failures', opt.maxFailures)
if (!opt.sourceEndpoints || !opt.sourceExplorerEndpoints || !opt.sourceNs || !opt.targetNs || !opt.agentAnchor ||
    !opt.agentInstance || !opt.keyBundle || !opt.keyPassphraseEnv) {
  die('source-endpoints, source-explorer-endpoints, source-ns, target-ns, agent-anchor, agent-instance, key-bundle, and key-passphrase-env are required')
}
if (opt.sourceNs === opt.targetNs) die('source-ns and target-ns must differ')
if (!opt.goal) die('goal must not be empty')
if (!['read', 'execute'].includes(opt.mode)) die('mode must be read or execute')
if (opt.insecureTls) process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'

const endpointSet = new Set()
for (const raw of opt.sourceEndpoints.split(',')) {
  const endpoint = raw.replace(/\/$/, '')
  try {
    const parsed = new URL(endpoint)
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.pathname !== '/') throw new Error()
  } catch { die(`bad source endpoint '${raw}'`) }
  endpointSet.add(endpoint)
}
const endpoints = [...endpointSet]
if (!endpoints.length) die('source-endpoints contained no endpoint')
const explorerEndpointSet = new Set()
for (const raw of opt.sourceExplorerEndpoints.split(',')) {
  const endpoint = raw.replace(/\/$/, '')
  try {
    const parsed = new URL(endpoint)
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.pathname !== '/') throw new Error()
  } catch { die(`bad source Explorer endpoint '${raw}'`) }
  explorerEndpointSet.add(endpoint)
}
const explorerEndpoints = [...explorerEndpointSet]
if (explorerEndpoints.length !== endpoints.length) {
  die('source-endpoints and source-explorer-endpoints must have the same number of endpoints')
}

function hexBytes(hex) {
  if (!/^[0-9a-f]{64}$/i.test(hex)) throw new Error('invalid genesis anchor')
  return Uint8Array.from(Buffer.from(hex, 'hex'))
}
const agent = {
  namespace: opt.sourceNs,
  anchor: hexBytes(opt.agentAnchor),
  instanceText: opt.agentInstance,
}
const passphrase = process.env[opt.keyPassphraseEnv]
if (!passphrase) die(`environment variable ${opt.keyPassphraseEnv} is not set`)
let provider
try {
  provider = await importEncryptedKeyProvider(
    await readFile(opt.keyBundle, 'utf8'), passphrase,
  )
} catch (error) {
  die(`could not open the configured agent key: ${String(error?.message || error)}`)
}
function remoteGoal(inner) {
  return `${opt.targetNs}::(${inner}).`
}
function goalFor(id) {
  return remoteGoal(opt.goal.replace(/\.$/, '').replaceAll('__QUOD_REQUEST_ID__', id))
}
function endpointPost(base) {
  return (path, body, method = 'POST') => postJson(new URL(path, `${base}/`).href, body, method)
}
async function summary(base) {
  const response = await fetch(new URL('/api/summary', `${base}/`), { signal: AbortSignal.timeout(httpTimeout * 1000) })
  if (!response.ok) throw new Error(`summary_http_${response.status}`)
  return response.json()
}
function outcomeText(error) {
  const message = String(error?.message || error).replaceAll('\t', ' ').replaceAll('\n', ' ')
  return error?.outcomeUnknown ? `outcome_unknown:${message}` : message
}
function boundedDetail(value) {
  let text
  try { text = typeof value === 'string' ? value : JSON.stringify(value) }
  catch { text = String(value) }
  return text.replaceAll('\t', ' ').replaceAll('\n', ' ').slice(0, 1024)
}
function failureClass(detail, error = null) {
  const text = detail.toLowerCase()
  if (error?.outcomeUnknown || text.includes('outcome_unknown') || text.includes('pending')) return 'uncertain'
  if (text.includes('cursor_busy')) return 'cursor_busy'
  if (text.includes('ontology_busy')) return 'ontology_busy'
  if (text.includes('not_allowed') || text.includes('policy')) return 'policy_failed'
  if (text.includes('conflict') || text.includes('occ')) return 'occ_failed'
  if (error?.status === undefined || error?.status === 0) return 'transport_failed'
  return 'goal_failed'
}
const noJournal = { async put() {}, async delete() {} }

const deadline = Date.now() + preflightTimeout * 1000
let sources = []
let preflightError = ''
while (Date.now() <= deadline && !sources.length) {
  try {
    const rows = []
    for (const [index, endpoint] of endpoints.entries()) {
      const state = await summary(explorerEndpoints[index])
      const source = state.namespaces?.filter(row => row.ns === opt.sourceNs) ?? []
      const target = state.namespaces?.filter(row => row.ns === opt.targetNs) ?? []
      if (source.length !== 1 || target.length !== 0 || source[0].syncing !== false) throw new Error('source missing, co-hosted target, or syncing source')
      if (source[0].genesis.toLowerCase() !== opt.agentAnchor.toLowerCase()) throw new Error('agent_anchor_does_not_match_source')
      const post = endpointPost(endpoint)
      const identity = await authenticateKey(provider, { post })
      // A signed remote read proves the actual source->target route and ACL
      // before the measured workload begins, without consuming a write goal.
      const warmup = await signedGoal(identity, {
        mode: 'read', agent,
        goal: remoteGoal('true'),
      }, { post })
      if (warmup.result !== 'ok') throw new Error(`warmup_${warmup.result || 'invalid'}`)
      rows.push({ endpoint, post, identity, height: source[0].height })
    }
    sources = rows
  } catch (error) {
    preflightError = outcomeText(error)
    await new Promise(resolve => setTimeout(resolve, 1000))
  }
}
if (!sources.length) die(`preflight did not establish signed remote proof: ${preflightError || 'unknown'}`)

const resultDir = opt.resultDir || `/tmp/quod-cross-ontology-${Date.now()}`
await mkdir(resultDir, { recursive: true })
await writeFile(`${resultDir}/preflight.tsv`, sources.map(row => `${row.endpoint}\t${opt.sourceNs}\t${opt.targetNs}\t${row.height}`).join('\n') + '\n')
console.log('cross-ontology signed fixed-work benchmark')
console.log(`  source:      ${opt.sourceNs} (${sources.length} endpoint(s))`)
console.log(`  target:      ${opt.targetNs}`)
console.log(`  remote goal: ${goalFor('<request-id>')}`)
console.log(`  mode:        ${opt.mode}`)
console.log(`  work:        ${requests} proofs at concurrency ${concurrency}`)

const started = process.hrtime.bigint()
const rows = new Array(requests)
let next = 0
const prefix = `q${Date.now()}_${process.pid}`
async function worker() {
  for (;;) {
    const number = next
    next += 1
    if (number >= requests) return
    const source = sources[number % sources.length]
    const began = process.hrtime.bigint()
    try {
      const reply = await signedGoal(source.identity, {
        mode: opt.mode, agent,
        goal: goalFor(`${prefix}_${number + 1}`),
      }, { post: source.post, journal: noJournal })
      const ok = reply?.result === 'ok'
      const detail = boundedDetail(reply)
      const category = ok ? (opt.mode === 'execute' ? 'committed' : 'read_ok') : failureClass(detail)
      rows[number] = [source.endpoint, 0, category, detail, Number((process.hrtime.bigint() - began) / 1000000n), ok ? 1 : 0]
    } catch (error) {
      const detail = outcomeText(error)
      rows[number] = [source.endpoint, error?.status ?? 0, failureClass(detail, error), detail, Number((process.hrtime.bigint() - began) / 1000000n), 0]
    }
  }
}
await Promise.all(Array.from({ length: concurrency }, worker))
const elapsed = Number((process.hrtime.bigint() - started) / 1000000n)
await writeFile(`${resultDir}/results.tsv`, rows.map(row => row.join('\t')).join('\n') + '\n')
const okRows = rows.filter(row => row[4] === 1)
const sorted = okRows.map(row => row[4]).sort((a, b) => a - b)
const percentile = p => sorted.length ? sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)] : 'nan'
const failures = rows.length - okRows.length
const rate = elapsed ? (okRows.length * 1000 / elapsed).toFixed(2) : 'nan'
const categories = new Map()
for (const row of rows) categories.set(row[2], (categories.get(row[2]) || 0) + 1)
console.log('\nresult')
console.log(`  operations: ${rows.length}`)
console.log(`  succeeded:  ${okRows.length}`)
console.log(`  failures:   ${failures}`)
console.log(`  outcomes:   ${[...categories].sort().map(([name, count]) => `${name}=${count}`).join(' ')}`)
console.log(`  latency:    p50=${percentile(.50)}ms p90=${percentile(.90)}ms p99=${percentile(.99)}ms`)
console.log(`  makespan:   ${elapsed}ms (${rate} successful remote proofs/s)`)
console.log('  queue wait: scrape quod_dtx_admission_wait_ms for the source namespace (dashboard row: Distributed transaction admission)')
console.log(`  raw data:   ${resultDir}/results.tsv`)
const cursorBusy = categories.get('cursor_busy') || 0
if (failures <= maxFailures && cursorBusy === 0) { console.log('PASS'); process.exit(0) }
if (cursorBusy > 0) console.error(`FAIL: cursor_busy=${cursorBusy}; distributed-write contention must queue before Begin`)
if (failures > maxFailures) console.error(`FAIL: failures=${failures} exceeds max-failures=${maxFailures}`)
process.exit(1)
