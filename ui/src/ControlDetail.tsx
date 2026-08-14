import type { Block, Control } from './api'
import { shortHex, timestamp } from './format'

export function ControlDetail({ ns, block, onClose }: { ns: string; block: Block; onClose: () => void }) {
  const control = block.control
  if (!control) return null
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
        <Dt>Ontology</Dt><dd className="font-mono">{ns}</dd>
        <Dt>Height</Dt><dd className="font-mono text-teal-light">#{block.slot}</dd>
        <Dt>Block time</Dt><dd>{timestamp(block.time)}</dd>
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
          <h3 className="mb-2 text-[11px] font-semibold tracking-wider text-rose uppercase">Abort reasons</h3>
          <ol className="space-y-1 font-mono text-[13px] text-teal">
            {control.reasons.map((reason, i) => <li key={`${i}:${reason}`} className="break-all">{reason}</li>)}
          </ol>
        </section>
      )}
    </aside>
  )
}

function ControlFields({ control }: { control: Control }) {
  return (
    <>
      {control.verdict && <><Dt>Verdict</Dt><dd className={control.verdict === 'abort' ? 'text-rose' : 'text-olive'}>{control.verdict}</dd></>}
      {control.participant_count != null && <><Dt>Participants</Dt><dd>{control.participant_count}</dd></>}
      {control.prepare_count != null && <><Dt>Prepared targets</Dt><dd>{control.prepare_count}</dd></>}
      {control.finalize_count != null && <><Dt>Finalized targets</Dt><dd>{control.finalize_count}</dd></>}
      {control.prepared != null && <><Dt>Prepared</Dt><dd>{control.prepared ? 'yes' : 'no'}</dd></>}
      {control.applied_generation != null && <><Dt>Applied generation</Dt><dd>{control.applied_generation}</dd></>}
      {control.plan_digest && <><Dt>Plan digest</Dt><dd className="font-mono text-xs break-all text-gray">{control.plan_digest}</dd></>}
      {control.request && <>
        <Dt>User request</Dt><dd>{control.request.status}</dd>
        <Dt>User</Dt><dd className="font-mono text-xs break-all">{control.request.user?.id ?? 'invalid'}</dd>
        <Dt>Request digest</Dt><dd className="font-mono text-xs break-all text-gray">{control.request.request_digest ?? 'invalid'}</dd>
        <Dt>Operation id</Dt><dd className="font-mono text-xs break-all text-gray">{control.request.operation_id ?? 'invalid'}</dd>
        <Dt>User signature</Dt><dd className="font-mono text-[11px] break-all text-gray">{control.request.signature ?? 'invalid'}</dd>
        <Dt>First outcome</Dt><dd className="font-mono text-xs break-all text-gray">{control.request.first_outcome?.group_id ?? 'invalid'}</dd>
      </>}
    </>
  )
}

function Dt({ children }: { children: React.ReactNode }) {
  return <dt className="text-[11px] leading-6 tracking-wider text-gray uppercase">{children}</dt>
}
