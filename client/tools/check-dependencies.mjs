import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'

// Build-time verification only. Installation owns applying dependency patches.
export function checkDependencies(root = new URL('../', import.meta.url)) {
  const read = path => readFileSync(new URL(path, root))
  const hash = bytes => createHash('sha256').update(bytes).digest('hex')
  const manifest = JSON.parse(read('patches/babylon.json'))
  const prefix = 'node_modules/@babylonjs/core/'
  const version = JSON.parse(read(prefix + 'package.json')).version
  if (version !== manifest.version || hash(read('patches/' + manifest.patch)) !== manifest.sha256 ||
      Object.entries(manifest.files).some(([path, digest]) => hash(read(prefix + path)) !== digest)) {
    throw new Error('Babylon dependency patch does not match the pinned client. Run the documented client installation before building or testing.')
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) checkDependencies()
