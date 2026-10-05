import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync, readdirSync, renameSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'

const fixture = fileURLToPath(new URL('./fixtures', import.meta.url))
const importer = fileURLToPath(new URL('../tools/import-eidolon.mjs', import.meta.url))
const work = mkdtempSync(join(tmpdir(), 'quod-import-check-'))
const source = join(fixture, 'asymmetric.glb')
const sha = bytes => createHash('sha256').update(bytes).digest('hex')
function imageHash(bytes) {
  const jsonLength = bytes.readUInt32LE(12)
  const document = JSON.parse(bytes.subarray(20, 20 + jsonLength).toString())
  const image = document.images[0]
  const view = document.bufferViews[image.bufferView]
  const start = 28 + jsonLength + (view.byteOffset ?? 0)
  return sha(bytes.subarray(start, start + view.byteLength))
}

function command(binary, args, expect = 0) {
  const result = spawnSync(binary, args, { encoding: 'utf8' })
  if (result.error) throw result.error
  assert.equal(result.status, expect, `${binary} ${args.join(' ')}: ${result.stderr}`)
  return result
}

function imported(path, extra = [], expect = 0) {
  const out = join(work, 'published')
  const unit = extra.includes('--source-meters-per-unit') ? [] :
    ['--source-meters-per-unit', '1']
  const result = command('node', [importer, path, '--out', out,
    '--licence', 'CC0-1.0', '--provenance', 'quod-authored-fixture',
    ...unit, ...extra], expect)
  return expect === 0 ? JSON.parse(result.stdout) : result.stderr
}

try {
  const version = command('assimp', ['version']).stdout
  assert.match(version, /Version 6\.0/)
  const direct = imported(source)
  assert.equal(direct.output.digest, sha(readFileSync(source)))
  assert.deepEqual(direct.output.costs.slice(2), [6, 2, 3, 2, 4])
  assert.deepEqual(direct.output.boundsMm, [-300, 0, -400, 1200, 1400, 300])
  const scaled = imported(source, ['--source-meters-per-unit', '0.01'])
  assert.deepEqual(scaled.output.boundsMm, [-3, 0, -4, 12, 14, 3])
  assert.equal(scaled.importer.name, 'quod-glb-repack')
  assert.equal(scaled.output.costs[4], 4)
  assert.match(imported(source, ['--metallic-factor', '0'], 1),
    /--metallic-factor requires/)
  const nonmetallic = imported(source,
    ['--metallic-factor', '0', '--accept-material-loss', 'yes'])
  assert.ok(nonmetallic.output.materialSummary.every(m => m.metallicFactor === 0))
  assert.equal(nonmetallic.importer.name, 'quod-glb-repack')
  assert.equal(nonmetallic.importer.options.metallicFactor, 0)
  assert.ok(nonmetallic.diagnostics.some(note => note.includes('metallic factor changed')))
  assert.notEqual(nonmetallic.output.digest, direct.output.digest)
  const corrupt = join(work, 'corrupt.glb')
  writeFileSync(corrupt, 'bad GLB')
  assert.match(imported(corrupt, ['--source-meters-per-unit', '0.01'], 1),
    /GLB profile: invalid GLB header/)

  const fbx = join(fixture, 'asymmetric.fbx')
  assert.match(imported(fbx, [], 1), /explicit --accept-material-loss/)
  assert.match(imported(fbx, ['--accept-material-loss', 'no'], 1), /only accepts yes/)
  const converted = imported(fbx, ['--accept-material-loss', 'yes'])
  assert.equal(converted.source.digest, sha(readFileSync(fbx)))
  assert.deepEqual(converted.output.costs.slice(2), [6, 2, 3, 2, 4])
  assert.equal(converted.output.boundsMm.every((n, i) =>
    Math.abs(n - direct.output.boundsMm[i]) <= 2), true)
  assert.ok(converted.diagnostics.some(note => note.includes('Discarded material extension')))
  assert.ok(converted.diagnostics.some(note => note.includes('change PBR optical factors')))
  assert.equal(converted.importer.version, '6.0')
  assert.match(converted.importer.build, /Version 6\.0/)
  assert.match(converted.importer.generator, /assimp/)
  assert.equal(converted.output.materialSummary.length, 2)
  assert.ok(converted.output.materialSummary[0].roughnessFactor < 0.8)
  assert.ok(converted.output.materialSummary[0].textured)
  assert.ok(converted.diagnostics.every(note => !note.includes('import took approx.')))
  assert.deepEqual(imported(fbx, ['--accept-material-loss', 'yes']), converted)
  const scaledFbx = imported(fbx, ['--accept-material-loss', 'yes',
    '--source-meters-per-unit', '0.01'])
  assert.deepEqual(scaledFbx.output.boundsMm, [-3, 0, -4, 12, 14, 3])
  const fbxGlb = readFileSync(join(work, 'published', `${converted.output.digest}.glb`))
  assert.equal(imageHash(fbxGlb), imageHash(readFileSync(source)))
  const fbxDoc = JSON.parse(fbxGlb.subarray(20, 20 + fbxGlb.readUInt32LE(12)).toString())
  assert.equal(fbxDoc.materials.length, 2)
  // This Assimp FBX round trip preserves image bytes but changes roughness.
  // The explicit loss choice and diagnostic keep this visible to the publisher.
  assert.notEqual(fbxDoc.materials[0].pbrMetallicRoughness.roughnessFactor, 0.8)
  assert.equal(sha(fbxGlb),
    converted.output.digest)

  const objSource = join(fixture, 'asymmetric.obj')
  assert.match(imported(objSource, [], 1), /explicit --accept-material-loss/)
  const obj = imported(objSource, ['--accept-material-loss', 'yes'])
  assert.deepEqual(obj.output.costs.slice(2, 4), [6, 2])
  assert.equal(obj.output.costs[6], 4)
  assert.deepEqual(obj.source.dependencies.map(item => item.name),
    ['asymmetric.mtl', 'texture.png'])

  for (const [extension, format] of [['gltf', 'gltf2'], ['stl', 'stl'], ['ply', 'ply']]) {
    const path = join(work, `asymmetric.${extension}`)
    command('assimp', ['export', source, path, `-f${format}`])
    const report = imported(path)
    assert.equal(report.output.costs[2], 6)
    assert.equal(report.output.costs[3], 2)
    if (extension === 'gltf') {
      assert.ok(report.source.dependencies.some(item => item.name.endsWith('.bin')))
      const binary = readdirSync(work).find(name => name.endsWith('.bin'))
      renameSync(join(work, binary), join(work, binary + '.missing'))
      assert.match(imported(path, [], 1), /missing external resource/)
      const escaped = join(work, 'escaping.gltf')
      const gltf = JSON.parse(readFileSync(path, 'utf8'))
      gltf.buffers[0].uri = '../outside.bin'
      writeFileSync(escaped, JSON.stringify(gltf))
      assert.match(imported(escaped, [], 1), /dependency escapes source directory/)
    }
  }
  const polygon = join(work, 'quad.ply')
  writeFileSync(polygon, [
    'ply', 'format ascii 1.0', 'element vertex 4',
    'property float x', 'property float y', 'property float z',
    'element face 1', 'property list uchar int vertex_indices',
    'end_header', '0 0 0', '1 0 0', '1 1 0', '0 1 0', '4 0 1 2 3', '',
  ].join('\n'))
  const quad = imported(polygon)
  assert.deepEqual(quad.output.costs.slice(2, 4), [4, 2])
  assert.deepEqual(quad.output.boundsMm, [0, 0, -1, 1000, 1000, 1])
  assert.ok(quad.diagnostics.some(note => note.includes('polygon topology metadata')))
  assert.ok(quad.diagnostics.some(note => note.includes('zero-thickness Z bounds')))
  process.stdout.write('Pinned GLB, glTF, FBX, OBJ, STL and polygon PLY import checks passed\n')
} finally { rmSync(work, { recursive: true, force: true }) }
