import { useId, useState } from 'react'
import type { GuiComponent } from '../../client/src/world.js'
import type { WorkspacePanelModel } from '../../client/src/world-scene.js'
import { numericControlRange, numericDraft, textFeedback, guiValueKind, choiceValues, choiceDraft, guiContainer, guiDisplay } from '../../client/src/gui-values.js'
import './gui-form.css'

// Desktop and spatial controls use the same controller model. Drafts, signed
// submissions and exact outcome recovery remain with that controller.
export function GuiForm({ model }: { model: WorkspacePanelModel }) {
  const [opacity, setOpacity] = useState(0.78)
  const [textScale, setTextScale] = useState(1)
  const opacityId = useId()
  return <section className="gui-form" aria-label={model.view.title} data-large-text={textScale > 1}
    style={{ backgroundColor: `rgb(25 43 50 / ${opacity})`, fontSize: `${textScale}rem` }}>
    <header><h2>{model.view.title}</h2><button type="button" onClick={model.close}>Close</button></header>
    <p className="gui-scope">{model.scope}</p>
    <div className="gui-opacity"><label htmlFor={opacityId}>Panel opacity</label>
      <input id={opacityId} type="range" min="0.5" max="1" step="0.01" value={opacity}
        onChange={event => setOpacity(Number(event.target.value))} />
      <output>{Math.round(opacity * 100)}%</output>
      <button type="button" onClick={() => setOpacity(1)}>Opaque</button>
      <button type="button" aria-label="Smaller text" disabled={textScale === 1}
        onClick={() => setTextScale(value => Math.max(1, value - 0.25))}>Text −</button>
      <button type="button" aria-label="Larger text" disabled={textScale === 2}
        onClick={() => setTextScale(value => Math.min(2, value + 0.25))}>Text +</button>
    </div>
    <div className={`gui-group gui-${model.view.layout ?? 'column'}`}>
      {model.view.fields.map(field => <GuiField key={field.role} field={field} model={model}
        inheritedEnabled={model.view.enabled !== false} />)}
    </div>
  </section>
}

function GuiField({ field, model, inheritedEnabled }: {
  field: GuiComponent; model: WorkspacePanelModel; inheritedEnabled: boolean
}) {
  const id = useId()
  const [selectedTab, setSelectedTab] = useState<string | null>(null)
  const enabled = inheritedEnabled && field.enabled !== false
  const editable = enabled && !model.locked && !field.readonly
  const value = model.values[field.role] ?? ''
  const edit = (next: string) => { if (editable) model.edit(field.role, next) }
  const activeTab = field.children?.some(child => child.role === selectedTab) ? selectedTab : field.children?.[0]?.role
  if (guiContainer(field.kind)) return <fieldset className="gui-container">
    <legend>{field.label}</legend>
    {field.help && <p>{field.help}</p>}
    {field.kind === 'tabs' && <div role="tablist" aria-label={field.label} className="gui-tablist">
      {field.children?.map((child, index) => {
        const selected = activeTab === child.role
        return <button type="button" role="tab" key={child.role} id={`${id}-tab-${index}`}
          aria-controls={`${id}-pane-${index}`} aria-selected={selected} disabled={!enabled}
          tabIndex={selected ? 0 : -1}
          onKeyDown={event => {
            const count = field.children?.length ?? 0
            const target = event.key === 'Home' ? 0 : event.key === 'End' ? count - 1
              : event.key === 'ArrowRight' ? (index + 1) % count : event.key === 'ArrowLeft' ? (index + count - 1) % count : null
            if (target !== null) {
              event.preventDefault(); setSelectedTab(field.children![target].role)
              document.getElementById(`${id}-tab-${target}`)?.focus()
            }
          }}
          onClick={event => { event.currentTarget.focus(); setSelectedTab(child.role) }}>{child.label}</button>
      })}
    </div>}
    <div className={`gui-group gui-${field.layout ?? 'column'} ${field.kind === 'scroll' ? 'gui-scroll' : ''}`}
      style={{ gridTemplateColumns: field.layout === 'grid' ? `repeat(auto-fit, minmax(min(100%, max(22rem, calc(100% / ${field.columns ?? 2} - 1rem))), 1fr))` : undefined,
        maxHeight: field.kind === 'scroll' ? `${(field.visibleRows ?? 6) * 3.5}em` : undefined }}>
      {field.children?.map((child, index) => field.kind === 'tabs'
        ? <div key={child.role} id={`${id}-pane-${index}`} role="tabpanel" aria-labelledby={`${id}-tab-${index}`}
            hidden={activeTab !== child.role}>
            <GuiField field={child} model={model} inheritedEnabled={enabled} />
          </div>
        : <GuiField key={child.role} field={child} model={model} inheritedEnabled={enabled} />)}
    </div>
  </fieldset>
  if (guiDisplay(field.kind)) return <div className={`gui-display gui-${field.kind}`}>
    <p role={field.kind === 'status' ? 'status' : field.kind === 'error' ? 'alert' : undefined}>{field.label}
      {field.kind === 'progress' && `: ${field.percent}%`}</p>
    {field.kind === 'separator' && <hr />}
    {field.kind === 'progress' && <progress aria-label={field.label} max={100} value={field.percent} />}
    {field.help && <p>{field.help}</p>}
  </div>
  if (field.kind === 'button') return <button type="button"
    disabled={!enabled || !model.enabled[field.role]} onClick={() => model.invoke(field.role)}>{field.label}</button>

  const family = guiValueKind(field.kind)
  const numeric = family === 'number'
  const range = numeric ? numericControlRange(field.range) : null
  const number = range ? numericDraft(range, value) : null
  const options = model.choices?.[field.role] ?? field.options ?? []
  const selected = family === 'choice' ? choiceValues({ ...field, options }, value) : null
  const knownSelection = selected !== null
  const error = range ? (number === null ? `Enter ${range.min} to ${range.last}, in steps of ${range.step}.` : '')
    : family === 'text' ? textFeedback(field, value)
    : family === 'choice' && (!knownSelection || (field.required && !selected?.length)) ? 'Choose a value.'
    : family === 'boolean' && field.required && value !== 'true' ? 'This field must be confirmed.' : ''
  const description = `${id}-description`
  return <div className="gui-field">
    <label htmlFor={id}>{field.label}{field.unit ? ` (${field.unit})` : ''}</label>
    {family === 'boolean' ? <input id={id} type="checkbox" role={field.kind === 'toggle' ? 'switch' : undefined}
      checked={value === 'true'} disabled={!editable} required={field.required}
      aria-describedby={description} aria-invalid={!!error}
      onChange={event => edit(String(event.target.checked))} />
      : field.kind === 'text_area' ? <textarea id={id} value={value} rows={5}
          disabled={!enabled || model.locked} readOnly={field.readonly}
          aria-describedby={description} aria-invalid={!!error} required={field.required}
          onChange={event => edit(event.target.value)} />
      : field.kind === 'text_box' ? <input id={id} type="text" value={value}
      disabled={!enabled || model.locked} readOnly={field.readonly}
      aria-describedby={description} aria-invalid={!!error} required={field.required}
      onChange={event => edit(event.target.value)} />
      : field.kind === 'radio_group' || field.kind === 'selectable_list' ? <div id={id}
          className="gui-choices" role="group" aria-label={field.label} aria-describedby={description}>
          {options.map(option => <label key={option.value}>
            <input type={field.multiple ? 'checkbox' : 'radio'} name={id}
              checked={selected?.includes(option.value) ?? false} disabled={!editable}
              onChange={() => edit(choiceDraft({ ...field, options }, value, option.value))} />
            {option.label}
          </label>)}
        </div>
      : field.kind === 'selection' ? <select id={id} value={value} disabled={!editable}
          aria-describedby={description} aria-invalid={!!error} onChange={event => edit(event.target.value)}>
          {!knownSelection && <option value={value} disabled>Choose a value.</option>}
          {options.map(option =>
            <option key={option.value} value={option.value}>{option.label}</option>)}
        </select>
      : range ? <div className="gui-number">
          {field.kind === 'rotary_knob' && number !== null && <span className="gui-dial" aria-hidden="true">
            <span style={{ transform: `rotate(${range.last === range.min ? 0 :
              -135 + 270 * (number - range.min) / (range.last - range.min)}deg)` }} />
          </span>}
          <button type="button" aria-label={`Decrease ${field.label}`}
            disabled={!editable || number === null || number <= range.min}
            onClick={() => { if (number !== null) edit(String(number - range.step)) }}>−</button>
          {number !== null && field.kind !== 'number_input' && <input type="range" min={range.min} max={range.last} step={range.step} value={number}
            aria-label={`Adjust ${field.label}`} disabled={!editable || range.min === range.last}
            onChange={event => edit(event.target.value)} />}
          <button type="button" aria-label={`Increase ${field.label}`}
            disabled={!editable || number === null || number >= range.last}
            onClick={() => { if (number !== null) edit(String(number + range.step)) }}>+</button>
          <input id={id} type="text" inputMode="numeric" value={value}
            disabled={!enabled || model.locked} readOnly={field.readonly}
            aria-invalid={!!error} aria-describedby={description} onChange={event => edit(event.target.value)} />
        </div>
      : <p>This control requires its dedicated editor.</p>}
    <div id={description} className="gui-description">
      {field.readonly && <p>Read only.</p>}
      {field.help && <p>{field.help}</p>}{error && <p className="gui-error" role="status">{error}</p>}
    </div>
  </div>
}
