#!/usr/bin/env node
// Offline publication preparation. This never changes an ontology; the signed
// recipe/publication transaction remains a separate authorized domain action.
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync, realpathSync } from 'node:fs'
import { basename, dirname, extname, join, resolve, sep } from 'node:path'
import { tmpdir } from 'node:os'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { validateGlb } from '../src/glb-profile.js'

const sha = bytes => createHash('sha256').update(bytes).digest('hex')
const formats = new Set(['.glb', '.gltf', '.fbx', '.obj', '.stl', '.ply'])
const options = new Map(), dependencies = []
let source
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i]
  if (arg === '--dependency') dependencies.push(process.argv[++i])
  else if (arg.startsWith('--')) {
    if (options.has(arg)) throw new Error(`duplicate option ${arg}`)
    options.set(arg, process.argv[++i])
  } else if (!source) source = arg
  else throw new Error(`unexpected argument ${arg}`)
}
const knownOptions = new Set(['--out', '--licence', '--provenance', '--front',
  '--pivot-mm', '--source-meters-per-unit', '--accept-material-loss', '--metallic-factor'])
for (const [name, value] of options) {
  if (!knownOptions.has(name) || value === undefined) throw new Error(`invalid option ${name}`)
}
if (options.has('--accept-material-loss') && options.get('--accept-material-loss') !== 'yes') {
  throw new Error('--accept-material-loss only accepts yes')
}
if (!source || !options.get('--out') || !options.get('--licence') ||
    !options.get('--provenance')) {
  throw new Error('usage: import-eidolon.mjs SOURCE --out DIR --licence ID ' +
    '--provenance URI [--front -z|+z|+x|-x] [--pivot-mm X,Y,Z] ' +
    '[--source-meters-per-unit N] [--dependency FILE] [--accept-material-loss yes] ' +
    '[--metallic-factor 0..1]')
}
const input = resolve(source), format = extname(input).toLowerCase()
if (!formats.has(format)) throw new Error(`unsupported source format ${format}`)
const front = options.get('--front') ?? '-z'
if (!['-z', '+z', '+x', '-x'].includes(front)) throw new Error('invalid front')
const pivot = (options.get('--pivot-mm') ?? '0,0,0').split(',').map(Number)
if (pivot.length !== 3 || pivot.some(n => !Number.isSafeInteger(n))) {
  throw new Error('pivot must be three integer millimetres')
}
const unit = Number(options.get('--source-meters-per-unit') ??
  (['.glb', '.gltf'].includes(format) ? '1' : 'NaN'))
if (!Number.isFinite(unit) || unit <= 0) {
  throw new Error('source-meters-per-unit is required for unitless/FBX imports')
}
const sourceBytes = readFileSync(input)
const diagnostic = []
const bundle = new Set(dependencies.map(file => resolve(file)))
function localDependency(uri, owner) {
  if (uri.startsWith('data:')) return
  if (/^[a-z][a-z0-9+.-]*:/i.test(uri) || uri.startsWith('/') || uri.startsWith('\\')) {
    throw new Error(`external dependency is not local: ${uri}`)
  }
  const path = resolve(dirname(owner), decodeURIComponent(uri))
  const sourceDirectory = dirname(input)
  if (!path.startsWith(sourceDirectory + sep) && path !== sourceDirectory) {
    throw new Error(`dependency escapes source directory: ${uri}`)
  }
  if (!existsSync(path)) throw new Error(`missing external resource: ${uri}`)
  const canonical = realpathSync(path), base = realpathSync(sourceDirectory)
  if (!canonical.startsWith(base + sep) && canonical !== base) {
    throw new Error(`dependency escapes source directory: ${uri}`)
  }
  bundle.add(canonical)
  return canonical
}
if (format === '.gltf') {
  const gltf = JSON.parse(sourceBytes.toString())
  for (const value of [...(gltf.buffers ?? []), ...(gltf.images ?? [])]) {
    if (value.uri) localDependency(value.uri, input)
  }
}
if (format === '.obj') {
  const obj = sourceBytes.toString()
  for (const line of obj.split(/\r?\n/)) {
    const match = /^\s*mtllib\s+(.+?)\s*$/.exec(line)
    if (match) localDependency(match[1], input)
  }
  for (const mtl of [...bundle].filter(file => extname(file).toLowerCase() === '.mtl')) {
    for (const line of readFileSync(mtl, 'utf8').split(/\r?\n/)) {
      const match = /^\s*map_\S+\s+(.+?)\s*$/.exec(line)
      if (match) localDependency(match[1], mtl)
    }
  }
}
for (const path of bundle) {
  if (!existsSync(path)) throw new Error(`missing external resource: ${path}`)
}

const acceptLoss = options.get('--accept-material-loss') === 'yes'
const metallicFactor = options.has('--metallic-factor') ?
  Number(options.get('--metallic-factor')) : null
if (metallicFactor !== null && (!Number.isFinite(metallicFactor) ||
    metallicFactor < 0 || metallicFactor > 1 || !acceptLoss)) {
  throw new Error('--metallic-factor requires a value from 0 to 1 and --accept-material-loss yes')
}
const sourceMaterials = format === '.fbx' ||
  (format === '.obj' && [...bundle].some(file => extname(file).toLowerCase() === '.mtl'))
if (sourceMaterials && !acceptLoss) {
  throw new Error(`source ${format} material conversion requires explicit --accept-material-loss yes`)
}
let data = sourceBytes, importer = { name: 'identity', version: 'gltf2-static-v1' }
if (format !== '.glb') {
  const version = spawnSync('assimp', ['version'], { encoding: 'utf8' })
  if (version.status !== 0 || !/Version 6\.0(?:\s|$)/.test(version.stdout)) {
    throw new Error('pinned Assimp 6.0 importer is required')
  }
  importer = { name: 'assimp', version: '6.0',
    build: version.stdout.trim().split(/\r?\n/).at(-1).trim(), exportFormat: 'glb2' }
  diagnostic.push('Assimp material mapping can change PBR optical factors; inspect the output material summary')
  const temp = mkdtempSync(join(tmpdir(), 'quod-eidolon-'))
  try {
    const output = join(temp, 'converted.glb')
    const job = spawnSync('assimp', ['export', input, output, '-fglb2'],
      { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 })
    if (job.status !== 0 || !existsSync(output)) {
      throw new Error(`Assimp conversion failed: ${(job.stdout + job.stderr).replace(/\r/g, '').slice(-4000)}`)
    }
    data = readFileSync(output)
  } finally { rmSync(temp, { recursive: true, force: true }) }
  data = normalizeExport(data, acceptLoss, diagnostic,
    ['.stl', '.ply'].includes(format) || (format === '.obj' && !sourceMaterials))
}
let admission = validateGlb(data)
if (unit !== 1) {
  data = repack(data, doc => {
    const roots = doc.scenes[doc.scene].nodes ?? []
    const wrapper = doc.nodes.length
    doc.nodes.push({ children: roots, scale: [unit, unit, unit] })
    doc.scenes[doc.scene].nodes = [wrapper]
  })
  admission = validateGlb(data)
}
if (metallicFactor !== null) {
  data = repack(data, doc => {
    for (const [slot, material] of (doc.materials ?? []).entries()) {
      const pbr = material.pbrMetallicRoughness ??= {}
      const previous = pbr.metallicFactor ?? 1
      pbr.metallicFactor = metallicFactor
      diagnostic.push(`Material ${slot} metallic factor changed from ${previous} to ${metallicFactor} by explicit request`)
    }
  })
  admission = validateGlb(data)
}
if (format === '.glb' && (unit !== 1 || metallicFactor !== null)) importer = {
  name: 'quod-glb-repack', version: 'gltf2-static-v1' }
const { costs, boundsMm, paddedAxes, document } = admission
for (const axis of paddedAxes) diagnostic.push(
  `Expanded zero-thickness ${axis} bounds by 1 mm for layout`)
const digest = sha(data)
const report = {
  schema: 'quod-eidolon-import-v1',
  source: { name: basename(input), format: format.slice(1), digest: sha(sourceBytes),
    dependencies: [...bundle].sort().map(path => ({ name: basename(path), digest: sha(readFileSync(path)) })) },
  output: { digest, profile: 'gltf2-static-v1', mediaType: 'model/gltf-binary',
    bytes: data.length, costs, boundsMm, pivotMm: pivot, front,
    materialSummary: (document.materials ?? []).map((material, slot) => ({
      slot, displayName: material.name ?? null,
      baseColorFactor: material.pbrMetallicRoughness?.baseColorFactor ?? [1, 1, 1, 1],
      metallicFactor: material.pbrMetallicRoughness?.metallicFactor ?? 1,
      roughnessFactor: material.pbrMetallicRoughness?.roughnessFactor ?? 1,
      textured: Boolean(material.pbrMetallicRoughness?.baseColorTexture),
    })) },
  importer: { ...importer, generator: document.asset.generator ?? null,
    options: { sourceMetersPerUnit: unit, acceptMaterialLoss: acceptLoss,
      metallicFactor } },
  provenance: { licence: options.get('--licence'), source: options.get('--provenance') },
  diagnostics: diagnostic,
}
const out = resolve(options.get('--out'))
mkdirSync(out, { recursive: true })
writeFileSync(join(out, `${digest}.glb`), data)
writeFileSync(join(out, `${digest}.json`), JSON.stringify(report, null, 2) + '\n')
process.stdout.write(JSON.stringify(report, null, 2) + '\n')

function repack(bytes, change) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  if (view.getUint32(0, true) !== 0x46546c67) throw new Error('not a GLB')
  const length = view.getUint32(12, true)
  const doc = JSON.parse(new TextDecoder().decode(bytes.subarray(20, 20 + length)))
  const binaryLength = view.getUint32(20 + length, true)
  const state = { bin: Buffer.from(bytes.subarray(28 + length, 28 + length + binaryLength)) }
  change(doc, state)
  const json = Buffer.from(JSON.stringify(doc))
  const padded = Buffer.concat([json, Buffer.alloc((4 - json.length % 4) % 4, 32)])
  const bin = Buffer.concat([state.bin, Buffer.alloc((4 - state.bin.length % 4) % 4)])
  const binHeader = Buffer.alloc(8)
  binHeader.writeUInt32LE(bin.length, 0)
  binHeader.write('BIN\0', 4)
  const header = Buffer.alloc(20)
  header.write('glTF', 0); header.writeUInt32LE(2, 4)
  header.writeUInt32LE(20 + padded.length + binHeader.length + bin.length, 8)
  header.writeUInt32LE(padded.length, 12); header.write('JSON', 16)
  return Buffer.concat([header, padded, binHeader, bin])
}

function normalizeExport(bytes, acceptLoss, notes, generatedMaterial) {
  return repack(bytes, (doc, state) => {
    const listed = new Set(doc.extensionsUsed ?? [])
    const safeDeclaration = 'FB_ngon_encoding'
    let polygonTopologyDropped = false
    for (const mesh of doc.meshes ?? []) for (const primitive of mesh.primitives ?? []) {
      const payload = primitive.extensions?.[safeDeclaration]
      if (payload === undefined) continue
      if ((primitive.mode ?? 4) !== 4 || primitive.indices === undefined ||
          !payload || Object.keys(payload).length !== 0) {
        throw new Error('FB_ngon_encoding requires indexed triangles and an empty payload')
      }
      delete primitive.extensions[safeDeclaration]
      if (Object.keys(primitive.extensions).length === 0) delete primitive.extensions
      polygonTopologyDropped = true
    }
    if (polygonTopologyDropped) notes.push('Discarded polygon topology metadata; indexed triangles remain')
    if (listed.has(safeDeclaration)) {
      if (JSON.stringify(doc).includes('"FB_ngon_encoding":')) {
        throw new Error('FB_ngon_encoding payload remains outside triangle primitives')
      }
      listed.delete(safeDeclaration)
      notes.push('Removed FB_ngon_encoding declaration after triangle export')
    }
    for (const material of doc.materials ?? []) {
      for (const name of Object.keys(material.extensions ?? {})) {
        if (!['KHR_materials_specular', 'KHR_materials_volume',
          'KHR_materials_ior'].includes(name) || (!acceptLoss && !generatedMaterial)) {
          throw new Error(`unsupported material extension ${name}; explicit --accept-material-loss yes is required to discard its optical effect`)
        }
        notes.push(`Discarded material extension ${name} ${generatedMaterial && !acceptLoss ? '(converter-generated)' : '(explicit consent)'}: ${JSON.stringify(material.extensions[name])}`)
        delete material.extensions[name]
        listed.delete(name)
      }
      if (material.extensions && Object.keys(material.extensions).length === 0) delete material.extensions
    }
    for (const name of listed) {
      if (!JSON.stringify(doc).includes(`"${name}":`)) {
        listed.delete(name)
        notes.push(`Removed unused ${name} declaration`)
      }
    }
    if (listed.size) throw new Error(`unsupported extension declarations: ${[...listed].join(', ')}`)
    delete doc.extensionsUsed
    for (const image of doc.images ?? []) {
      if (image.uri === undefined) continue
      let imageBytes, mime
      if (image.uri.startsWith('data:')) {
        const match = /^data:(image\/(?:png|jpeg));base64,(.+)$/.exec(image.uri)
        if (!match) throw new Error('unsupported embedded image data URI')
        mime = match[1]
        imageBytes = Buffer.from(match[2], 'base64')
      } else {
        const path = localDependency(image.uri, input)
        const ext = extname(image.uri).toLowerCase()
        mime = ext === '.png' ? 'image/png' :
          ['.jpg', '.jpeg'].includes(ext) ? 'image/jpeg' : null
        if (!mime) throw new Error(`unsupported image format ${ext}`)
        imageBytes = readFileSync(path)
      }
      const aligned = Buffer.alloc((4 - state.bin.length % 4) % 4)
      state.bin = Buffer.concat([state.bin, aligned])
      const offset = state.bin.length
      state.bin = Buffer.concat([state.bin, imageBytes])
      doc.bufferViews.push({ buffer: 0, byteOffset: offset,
        byteLength: imageBytes.length })
      image.bufferView = doc.bufferViews.length - 1
      image.mimeType = mime
      delete image.uri
      doc.buffers[0].byteLength = state.bin.length
      notes.push(`Embedded verified image ${sha(imageBytes)} (${mime})`)
    }
  })
}
