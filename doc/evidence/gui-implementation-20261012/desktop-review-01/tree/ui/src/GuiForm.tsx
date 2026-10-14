import { useId, useState } from 'react'
import type { GuiComponent } from '../../client/src/world.js'
import type { WorkspacePanelModel } from '../../client/src/world-scene.js'
import { numericControlRange, numericDraft, textFeedback } from '../../client/src/gui-values.js'
import './gui-form.css'

// Desktop and spatial controls use the same controller model. Drafts, signed
// submissions and exact outcome recovery remain with that controller.
export function GuiForm({ model }: { model: WorkspacePanelModel }) {
  const [opacity, setOpacity] = useState(0.78)
  return <section className="gui-form" aria-label={model.view.title}
    style={{ backgroundColor: `rgb(25 43 50 / ${opacity})` }}>
    <header><h2>{model.view.title}</h2><button type="button" onClick={model.close}>Close</button></header>
    <p className="gui-scope">{model.scope}</p>
    <label className="gui-opacity">Panel opacity
      <input type="range" min="0.5" max="1" step="0.01" value={opacity}
        onChange={event => setOpacity(Number(event.target.value))} />
      <output>{Math.round(opacity * 100)}%</output>
      <button type="button" onClick={() => setOpacity(1)}>Opaque</button>
    </label>
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
  const enabled = inheritedEnabled && field.enabled !== false
  const editable = enabled && !model.locked && !field.readonly
  const value = model.values[field.role] ?? ''
  const edit = (next: string) => { if (editable) model.edit(field.role, next) }
  if (field.kind === 'form' || field.kind === 'container') return <fieldset className="gui-container">
    <legend>{field.label}</legend>
    {field.help && <p>{field.help}</p>}
    <div className={`gui-group gui-${field.layout ?? 'column'}`}>
      {field.children?.map(child => <GuiField key={child.role} field={child} model={model}
        inheritedEnabled={enabled} />)}
    </div>
  </fieldset>
  if (field.kind === 'button') return <button type="button"
    disabled={!enabled || !model.enabled[field.role]} onClick={() => model.invoke(field.role)}>{field.label}</button>

  const numeric = field.kind === 'slider' || field.kind === 'rotary_knob'
  const range = numeric ? numericControlRange(field.range) : null
  const number = range ? numericDraft(range, value) : null
  const options = model.choices?.[field.role] ?? field.options ?? []
  const knownSelection = options.some(option => option.value === value)
  const error = range ? (number === null ? `Enter ${range.min} to ${range.last}, in steps of ${range.step}.` : '')
    : field.kind === 'text_box' ? textFeedback(field, value)
    : field.kind === 'selection' && !knownSelection ? 'Choose a value.' : ''
  const description = `${id}-description`
  return <div className="gui-field">
    <label htmlFor={id}>{field.label}{field.unit ? ` (${field.unit})` : ''}</label>
    {field.kind === 'text_box' ? <input id={id} type="text" value={value} disabled={!editable}
      aria-describedby={description} aria-invalid={!!error} required={field.required}
      onChange={event => edit(event.target.value)} />
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
          {number !== null && <input type="range" min={range.min} max={range.last} step={range.step} value={number}
            aria-label={`Adjust ${field.label}`} disabled={!editable || range.min === range.last}
            onChange={event => edit(event.target.value)} />}
          <button type="button" aria-label={`Increase ${field.label}`}
            disabled={!editable || number === null || number >= range.last}
            onClick={() => { if (number !== null) edit(String(number + range.step)) }}>+</button>
          <input id={id} type="text" inputMode="numeric" value={value} disabled={!editable}
            aria-invalid={!!error} aria-describedby={description} onChange={event => edit(event.target.value)} />
        </div>
      : <p role="alert">This control requires its dedicated editor.</p>}
    <div id={description} className="gui-description">
      {field.help && <p>{field.help}</p>}{error && <p className="gui-error" role="status">{error}</p>}
    </div>
  </div>
}
