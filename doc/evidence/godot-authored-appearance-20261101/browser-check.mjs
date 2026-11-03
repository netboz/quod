import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
process.on('uncaughtException', error => { console.error(error.message); process.exitCode = 1 })

const root = pathToFileURL(`${process.cwd()}/client/src/`)
const selected = process.argv[2]
// Retained before-source imports use the exact same current dependency owners.
const bytes = await readFile(selected, 'utf8')
const executable = bytes.replace(/from '(\.\/?[^']+)'/g, (_, path) => `from '${new URL(path, root)}'`)
const world = await import(`data:text/javascript;base64,${Buffer.from(executable).toString('base64')}`)
const { readTerm } = await import(new URL('prolog-read.js', root))
const { renderTerm } = await import(new URL('prolog-term.js', root))
const tree = 'component(f,form,[property(label,<<"Instrument">>),property(appearance,inherit)],[component(name,text_box,[property(label,<<"Name">>)],[]),component(apply,button,[property(label,<<"Apply">>)],[])])'
const fields = '[field(name,<<"dirty local value">>)]'
const ordinary = world.readGuiForm(readTerm(tree), readTerm(fields), readTerm('apply'))
assert.equal(ordinary.values.name, 'dirty local value')
assert.equal(ordinary.submit, 'apply')
console.log('PASS existing browser form consumes the shared explicit inherit declaration')
const anchor = `<<"${'a'.repeat(32)}">>`
const question = `question_form(form_ref(<<"owner">>,${anchor},f),agent_instance_ref(<<"human">>,${anchor},me),${anchor},awaiting,form_view(${anchor},${tree},${anchor},${fields},apply))`
assert.equal(world.readGuiQuestionForm(question).interaction, 'editable')
console.log('PASS ordinary browser question still admits the same revision and native fields')
for (const appearance of ['appearance(1,[token(accent,rgb(80,200,240))])', 'appearance(2,[])', 'inherit(extra)']) {
  assert.throws(() => world.readGuiView(tree.replace('property(appearance,inherit)', `property(appearance,${appearance})`)), /supporting renderer/)
}
console.log('PASS unsupported authored appearance fails explicitly in the browser adapter')
assert.throws(() => world.readGuiView(tree.replace('property(appearance,inherit)', 'property(appearance,inherit),property(appearance,inherit)')), /invalid component property/)
console.log('PASS repeated appearance property is refused')
if (selected === 'client/src/world.js') {
  const { readOperations, operationGoal } = await import(new URL('gui-operation.js', root))
  const subject = readTerm(`entity_ref(<<"owner">>,${anchor},instrument)`)
  const [operation] = readOperations(`[operation_view(configure,${renderTerm(subject)},${anchor},${tree},${anchor},${fields},apply,[],available)]`, subject)
  assert.equal(operationGoal(operation, ordinary.values).includes('apply,[field(name,<<"dirty local value">>)]'), true)
  console.log('PASS actual browser operation caller retains exact target submit and values')
}
console.log('BROWSER_APPEARANCE_PASS')
