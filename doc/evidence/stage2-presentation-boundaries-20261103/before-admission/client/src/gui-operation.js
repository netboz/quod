import { atom, binary, compound, variable, renderTerm } from './prolog-term.js'
import { readTerm, readList, requireProjection } from './prolog-read.js'
import { anchoredGoal, singleBinding, readGuiForm, guiDigest, guiDraftFields } from './world.js'
import { signedGoal } from './signed-client.js'
import { connectSignedView, readViewIdentity } from './signed-view.js'
import { fromB64url } from './key-provider.js'

export function operationSubject(reference, kind, entity) {
  if (!['class', 'entity'].includes(kind)) throw new Error('Invalid operation subject.')
  anchoredGoal(reference, entity)
  const subject = compound(`${kind}_ref`, [binary(new TextEncoder().encode(reference.namespace)),
    binary(reference.anchor), entity])
  requireProjection(subject)
  return subject
}

export async function readOperationClasses(identity, human, reference, options = {}) {
  const reply = await signedGoal(identity, { mode: 'read', agent: human,
    goal: anchoredGoal(reference, compound('gui_operation_classes', [variable('Classes')])) }, options)
  return readList(singleBinding(reply, 'Classes')).map(value => { requireProjection(value); return renderTerm(value) })
}

export function readOperations(value, subject) {
  const names = new Set()
  return readList(value).map(term => {
    requireProjection(term)
    if (term.type !== 'compound' || term.functor !== 'operation_view' || term.args.length !== 9) throw new Error('Invalid offered operation.')
    const [name, exact, revision, tree, token, fields, control, outputs, availability] = term.args
    if (name.type !== 'atom' || names.has(name.value) || renderTerm(exact) !== renderTerm(subject) ||
        availability.type !== 'atom' || !['available', 'unavailable', 'requires_input'].includes(availability.value) ||
        outputs.type !== 'list' || outputs.tail !== null || outputs.items.some(item => item.type !== 'atom')) {
      throw new Error('Invalid operation binding.')
    }
    names.add(name.value)
    return { name: name.value, subject, revision: guiDigest(revision), valuesToken: guiDigest(token),
      ...readGuiForm(tree, fields, control), outputs: outputs.items.map(item => item.value), availability: availability.value }
  })
}

export function connectOperations(identity, human, reference, subject, callbacks, options = {}) {
  return connectSignedView(identity, human, reference, 'gui_operations',
    anchoredGoal(reference, compound('gui_operations', [subject, variable('View')])), {
      decode(message) {
        if (message.kind !== 'gui_operations') throw new Error('Unexpected operation view.')
        return { ...readViewIdentity(message), operations: readOperations(message.value, subject) }
      },
    }, { ...callbacks, projection: current => callbacks.projection(current.operations) }, options)
}

export function operationGoal(form, draft) {
  return `${renderTerm(compound('gui_operation', [form.subject, atom(form.name),
    binary(fromB64url(form.revision)), readTerm(form.submit), guiDraftFields(form.view, draft), variable('Results')]))}.`
}
