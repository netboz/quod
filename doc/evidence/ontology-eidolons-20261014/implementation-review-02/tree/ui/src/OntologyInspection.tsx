import { useEffect, useState } from 'react'
import { useSignedSession } from './session-context'
import { readTextProjection } from '../../client/src/world.js'
import type { EidolonRepresentation } from '../../client/src/world.js'
import { compound, binary, variable } from '../../client/src/prolog-term.js'
import { b64url } from '../../client/src/key-provider.js'

type InspectionProps = {
  representation: Extract<EidolonRepresentation, { kind: 'lens' }>; title: string; onClose: () => void
}

export function OntologyInspection(props: InspectionProps) {
  const { identity, agent } = useSignedSession()
  const scope = JSON.stringify([identity?.networkId, identity?.provider.publicKey, agent, props.representation])
  return <ScopedInspection key={scope} {...props} />
}

function ScopedInspection({ representation, title, onClose }: InspectionProps) {
  const { identity, agent } = useSignedSession()
  const [text, setText] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [revision, setRevision] = useState(0)
  useEffect(() => {
    const controller = new AbortController()
    setText(null); setError(null)
    if (identity && agent) {
      const goal = compound('view', [binary(new TextEncoder().encode(representation.view)),
        representation.parameters, variable('View')])
      void readTextProjection(identity, agent, representation.lens, goal, 'View', controller.signal)
        .then(value => { if (!controller.signal.aborted) setText(value) })
        .catch(reason => { if (!controller.signal.aborted) setError(String(reason)) })
    }
    return () => controller.abort()
  }, [identity, agent, representation, revision])
  return <section className="console">
    <h2>{title}</h2>
    <p>{representation.target.namespace} · {b64url(representation.target.anchor)}</p>
    <p>Source read and policy read disclose knowledge. Invocation, content edits and policy edits are authorized separately by the current owner.</p>
    {error ? <p role="alert">{error}</p> : text === null ? <p role="status">Reading…</p>
      : <pre>{text || 'No declarations.'}</pre>}
    <button onClick={() => setRevision(value => value + 1)}>Refresh</button>
    <button onClick={onClose}>Close</button>
  </section>
}
