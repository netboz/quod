import type { Control } from './api'
import { shortHex, timestamp } from './format'
import type { LiveControl } from './store'

export function ControlDetail({ row, onClose }: { row: LiveControl; onClose: () => void }) {
  const control = row.control
  return (
    <aside className="flex h-full flex-col overflow-y-auto rounded-xl border border-gray/25 bg-white shadow-sm">
      <header className="flex items-center justify-between border-b border-gray/20 bg-teal px-4 py-3 text-cream">
        <div>
          <div className="text-[11px] tracking-wider text-gray uppercase">Durable transaction control</div>
          <div className="font-mono text-sm">{control.kind}</div>
        </div>
        <button onClick={onClose} className="rounded-lg px-2 py-1 text-gray hover:bg-teal-light hover:text-cream">
          ✕
        </button>
      </header>
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 px-4 py-3 text-sm">
        <Dt>Ontology</Dt><dd className="font-mono">{row.ns}</dd>
        <Dt>Height</Dt><dd className="font-mono text-teal-light">#{row.height}</dd>
        <Dt>Block time</Dt><dd>{timestamp(row.time)}</dd>
        <Dt>Group id</Dt><dd className="font-mono text-xs break-all">{control.group_id}</dd>
        <Dt>Record digest</Dt><dd className="font-mono text-xs break-all text-gray">{control.record_digest}</dd>
        <Dt>Target</Dt>
        <dd className="font-mono text-xs break-all">
          {control.target ? `${control.target.ns} (${shortHex(control.target.anchor, 12)})` : '—'}
        </dd>
        <Dt>Author</Dt><dd className="font-mono text-xs" title={control.author.pubkey ?? undefined}>{control.author.id}</dd>
        <Dt>Sequence</Dt><dd className="font-mono">{control.sequence}</dd>
        <Dt>Submitted</Dt><dd>{timestamp(control.submitted_at)}</dd>
        <ControlFields control={control} />
      </dl>
      {control.reasons && control.reasons.length > 0 && (
        <section className="border-t border-rose/20 bg-rose/5 px-4 py-3">
          <h3 className="mb-2 text-[11px] font-semibold tracking-wider text-rose uppercase">Refusal / abort reasons</h3>
          <ol className="space-y-1 font-mono text-[13px] text-teal">
            {control.reasons.map((reason, i) => <li key={`${i}:${reason}`} className="break-all">{reason}</li>)}
          </ol>
        </section>
      )}
      {control.plan && (
        <section className="border-t border-gray/20 px-4 py-3">
          <h3 className="mb-2 text-[11px] font-semibold tracking-wider text-gray uppercase">Own staged plan</h3>
          <ParticipantPlan plan={control.plan} />
        </section>
      )}
      {control.kind === 'resolve' && (
        <section className="border-t border-gray/20 px-4 py-3 text-sm text-gray">
          {control.verdict === 'commit'
            ? `Applies this ontology’s staged plan from Vote #${control.vote_ref?.height}.`
            : 'No staged changes were applied.'}
        </section>
      )}
    </aside>
  )
}

function ParticipantPlan({ plan }: { plan: NonNullable<Control['plan']> }) {
  return (
    <div className="rounded-lg border border-gray/20 bg-teal/5 p-2 text-xs">
      <div className="flex justify-between gap-2">
        <span className="font-mono break-all">{plan.target ? plan.target.ns : 'invalid target'}</span>
        <span className={plan.status === 'bound' ? 'text-olive' : 'text-rose'}>{plan.status}</span>
      </div>
      <div className="mt-1 font-mono text-[10px] break-all text-gray">{plan.plan_digest}</div>
      <div className="mt-1 text-gray">fact changes: {plan.diff_ops ?? 'invalid'} · effects: {plan.effect_count ?? 'invalid'}</div>
      {plan.diff && plan.diff.length > 0 && (
        <div className="mt-2 rounded border border-teal/15 bg-cream p-2">
          <div className="text-[10px] font-semibold tracking-wider text-gray uppercase">Staged changes (not applied by Vote)</div>
          <ol className="mt-1 space-y-1 font-mono text-[11px] break-all text-teal">
            {plan.diff.map((op, index) => (
              <li key={`${index}:${op.op}:${op.op === 'event' ? op.term : op.clause}`}>
                <span className={op.op === 'retract' ? 'text-rose' : 'text-olive'}>{op.op}</span>
                {' '}{op.op === 'event' ? op.term : op.clause}
              </li>
            ))}
          </ol>
        </div>
      )}
      {plan.effects.map((effect) => (
        <div key={effect.effect_id} className="mt-2 rounded border border-teal/15 bg-cream p-2">
          <div className="flex justify-between gap-2">
            <span className="font-semibold text-teal">{effect.operation}</span>
            <span className="text-gray">{effect.local_execution.replaceAll('_', ' ')}</span>
          </div>
          <div className="mt-1 font-mono break-all">target: {effect.target.ns}</div>
          <div className="font-mono text-[10px] break-all text-gray">effect: {effect.effect_id}</div>
          <div className="font-mono text-[10px] break-all text-gray">executor: {effect.executor.id}</div>
          <div className="font-mono text-[10px] break-all text-gray">
            actor: {effect.actor.kind === 'agent' ? effect.actor.reference : `node:${effect.actor.identity.id}`}
          </div>
          {effect.local_custody_state && (
            <div className="mt-1 text-gray">local custody: {effect.local_custody_state.replaceAll('_', ' ')}</div>
          )}
        </div>
      ))}
    </div>
  )
}

function ControlFields({ control }: { control: Control }) {
  return (
    <>
      {control.verdict && <><Dt>Verdict</Dt><dd className={control.verdict === 'abort' ? 'text-rose' : 'text-olive'}>{control.verdict}</dd></>}
      {control.vote && <><Dt>Vote</Dt><dd>{control.vote}</dd></>}
      {control.vote_deadline_ms != null && <><Dt>Vote deadline</Dt><dd>{timestamp(control.vote_deadline_ms)}</dd></>}
      {control.participant_count != null && <><Dt>Participants</Dt><dd>{control.participant_count}</dd></>}
      {control.resolve_count != null && <><Dt>Resolved targets</Dt><dd>{control.resolve_count}</dd></>}
      {control.voted != null && <><Dt>Own vote recorded</Dt><dd>{control.voted ? 'yes' : 'no'}</dd></>}
      {control.applied_generation != null && <><Dt>Applied generation</Dt><dd>{control.applied_generation}</dd></>}
      {control.request && <>
        <Dt>Agent request</Dt><dd>{control.request.status}</dd>
        <Dt>Agent</Dt><dd className="font-mono text-xs break-all">{control.request.agent?.reference ?? 'invalid'}</dd>
        <Dt>Request digest</Dt><dd className="font-mono text-xs break-all text-gray">{control.request.request_digest ?? 'invalid'}</dd>
        <Dt>Operation id</Dt><dd className="font-mono text-xs break-all text-gray">{control.request.operation_id ?? 'invalid'}</dd>
        <Dt>Agent signature</Dt><dd className="font-mono text-[11px] break-all text-gray">{control.request.signature ?? 'invalid'}</dd>
        <Dt>First outcome</Dt><dd className="font-mono text-xs break-all text-gray">{control.request.first_outcome?.group_id ?? 'invalid'}</dd>
      </>}
    </>
  )
}

function Dt({ children }: { children: React.ReactNode }) {
  return <dt className="text-[11px] leading-6 tracking-wider text-gray uppercase">{children}</dt>
}
