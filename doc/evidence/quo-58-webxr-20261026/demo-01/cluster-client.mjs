import assert from 'node:assert/strict'
import { webcrypto } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { authenticateKey, signedGoal, personalGoal, pendingSignedOperations } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/signed-client.js'
import { createAccount, accountReference, readPersonalAgent } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/accounts.js'
import { memoryOperationJournal } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/operation-journal.js'
import { readSpaceNavigation, anchoredGoal, singleBinding } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/world.js'
import { readOperationClasses, operationSubject, readOperations, operationGoal } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/gui-operation.js'
import { compound, variable, atom, renderTerm } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/prolog-term.js'
import { readList, readTerm } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/prolog-read.js'
import { b64url, fromB64url } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/key-provider.js'
import { committed } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/space-entry.js'

import { readControllerView } from '/home/yan/src/quod/_build/quo-58-webxr-20261026/demo-01/release-tree-01/client/src/controller-view.js'

globalThis.crypto ??= webcrypto
const [origin, evidence] = process.argv.slice(2)
assert.equal(origin, 'https://192.168.1.10:30519')
assert.equal(new URL(origin).protocol, 'https:')
const nativeFetch = globalThis.fetch
const requests = []
globalThis.fetch = async (url, options) => {
  const address = new URL(url, origin)
  assert.equal(address.origin, origin)
  const response = await nativeFetch(address, options)
  requests.push({ path: address.pathname, status: response.status })
  return response
}
const record = (name, value) => writeFileSync(join(evidence, name), JSON.stringify(value, null, 2), { mode: 0o600 })
const reports = []
const pass = (step, detail) => { reports.push({ step, result: 'pass', ...detail }); console.log(`PASS ${step}`) }
try {
  const diagnostic = process.env.QUOD_PREFLIGHT_MODE === 'diagnose'
  const pair = diagnostic ? null : await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify'])
  const jwk = diagnostic ? JSON.parse(readFileSync(join(evidence, 'private-browser-key.json')))
    : await crypto.subtle.exportKey('jwk', pair.privateKey)
  const privateKey = pair?.privateKey ?? await crypto.subtle.importKey('jwk', jwk, 'Ed25519', false, ['sign'])
  const provider = { publicKey: fromB64url(jwk.x), sign: bytes => crypto.subtle.sign('Ed25519', privateKey, bytes) }
  if (diagnostic) provider.accounts = JSON.parse(readFileSync(join(evidence, 'private-account.json'))).accounts
  record('private-browser-key.json', jwk)
  const identity = await authenticateKey(provider)
  const journal = memoryOperationJournal()
  const durable = { list: () => journal.list() }
  for (const method of ['put', 'delete', 'replace']) durable[method] = async (...args) => {
    await journal[method](...args); record('private-operations.json', await journal.list())
  }
  const options = { journal: durable, storeIdentity: async value => record('private-account.json', value), saveReference: value => value }
  if (!diagnostic) {
    const created = await createAccount(identity, options)
    assert(committed(created)); assert.equal(created.unresolved, 0)
  }
  const human = accountReference(identity)
  assert(human)
  const controllerReply = await signedGoal(identity, { mode: 'read', agent: human,
    goal: compound('controller_preferences_view', [readTerm(human.instanceText.replace(/\.\s*$/, '')), variable('View')]) }, options)
  const mapping = readControllerView(singleBinding(controllerReply, 'View'))
  assert(mapping && mapping.revision === 0 && mapping.profiles.length === 1)
  assert.equal(mapping.profiles[0].model.digest, 'bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94')
  pass('fresh account has authorized controller definitions and pinned appearance', {
    revision: mapping.revision, roles: mapping.roles, bindings: mapping.bindings.map(b => b.id),
    profiles: mapping.profiles.map(p => ({ class: p.class, names: p.names, model: p.model.digest })),
  })
  const personal = await readPersonalAgent(identity, human, options)
  assert.notEqual(personal.agent.instanceText, human.instanceText)
  pass('normal account and distinct personal agent', { human: human.instanceText, personal: personal.agent.instanceText })
  const navigation = await readSpaceNavigation(identity, human, null, options)
  const storage = navigation.reference
  const classes = await readOperationClasses(identity, human, storage, options)
  assert(classes.includes('space'))
  assert.deepEqual(await readOperationClasses(identity, human, storage, options), classes)
  pass('explicit storage class discovery and unchanged repeat', { classes, storage: storage.namespace, anchor: b64url(storage.anchor) })
  const location = await signedGoal(identity, { mode: 'read', agent: human,
    goal: 'space_location(personal, Location).' }, options)
  assert.equal(location.result, 'ok')
  assert.equal(singleBinding(location, 'Location'), 'unplaced')
  pass('ordinary signup gives the personal agent a readable unplaced location', {})
  const subject = operationSubject(storage, 'class', atom('space'))
  for (const [name, operation, overrides] of [
    ['infinite extent', 'create_infinite', { Name: 'XR demo01 infinite acceptance' }],
  ]) {
    const result = await signedGoal(identity, { mode: 'read', agent: human,
      goal: anchoredGoal(storage, compound('gui_operations', [subject, variable('View')])) }, options)
    const forms = readOperations(singleBinding(result, 'View'), subject)
    const form = forms.find(row => row.name === operation)
    assert(form)
    const draft = { ...form.values }
    const leaves = fields => fields.flatMap(field => field.children ? leaves(field.children) : [field])
    for (const [label, value] of Object.entries(overrides)) {
      const field = leaves(form.view.fields).find(row => row.label === label)
      assert(field, label); draft[field.role] = value
    }
    const reply = await personalGoal(identity, { human, ...personal, target: storage,
      goal: operationGoal(form, draft) }, options)
    record(`create-${operation}-${reports.length}.json`, reply)
    assert(committed(reply), 'Uncertain creation must be recovered, never resubmitted.')
    const outputs = readList(singleBinding(reply, 'Results'))
    const space = outputs.find(row => row.args[0].value === 'space').args[1]
    assert.equal(space.functor, 'entity_ref')
    const entity = space.args[2]
    const facts = await signedGoal(identity, { mode: 'read', agent: human,
      goal: anchoredGoal(storage, compound(',', [compound('instance_of', [atom('space'), entity]),
        compound(',', [compound('attribute', [entity, atom('owner'), variable('Owner')]),
          compound(',', [compound('attribute', [entity, atom('dimensions'), variable('Dimensions')]),
            compound('space_location', [entity, variable('Location')])])])])) }, options)
    assert.equal(facts.result, 'ok')
    assert(singleBinding(facts, 'Owner').includes('me'))
    if (operation === 'create_infinite') assert.equal(singleBinding(facts, 'Dimensions'), 'infinite')
    pass(`Create-space ${name}`, { identity: renderTerm(space), actual: facts.bindings,
      output: outputs.map(renderTerm) })
  }
  assert.equal((await pendingSignedOperations(identity, options)).length, 0)
} finally {
  record('results.json', reports)
  record('http-path-status.json', requests)
}
