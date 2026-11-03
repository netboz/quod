import { useMemo, useRef, useState } from 'react'
import { highlightProlog } from '../../client/src/prolog-highlight.js'
import './prolog-text.css'

// One native text control owns selection, clipboard, undo and accessibility.
// Its inert, escaped highlight layer follows the same text and scroll offsets.
export function PrologText({ value, label, readOnly, disabled, onChange }: {
  value: string; label: string; readOnly: boolean; disabled: boolean; onChange: (value: string) => void
}) {
  const input = useRef<HTMLTextAreaElement>(null)
  const ink = useRef<HTMLPreElement>(null)
  const [search, setSearch] = useState('')
  const [position, setPosition] = useState('Line 1, column 1')
  const [searchResult, setSearchResult] = useState('')
  const tokens = useMemo(() => highlightProlog(value), [value])
  const select = () => {
    const area = input.current
    if (!area) return
    const prefix = value.slice(0, area.selectionStart)
    setPosition(`Line ${prefix.split('\n').length}, column ${prefix.length - prefix.lastIndexOf('\n')}`)
  }
  const indent = (outdent = false) => {
    const area = input.current
    if (!area || readOnly || disabled) return
    area.focus()
    if (!outdent && area.selectionStart === area.selectionEnd) {
      document.execCommand('insertText', false, '    ')
      return
    }
    const start = area.selectionStart === 0 ? 0 : value.lastIndexOf('\n', area.selectionStart - 1) + 1
    let end = area.selectionEnd
    if (outdent && area.selectionStart === end) {
      const newline = value.indexOf('\n', end)
      end = newline < 0 ? value.length : newline
    }
    if (end > start && value[end - 1] === '\n') end--
    const block = value.slice(start, end)
    const replacement = outdent ? block.replace(/^( {1,4}|\t)/gm, '') : block.replace(/^/gm, '    ')
    area.setSelectionRange(start, end)
    document.execCommand('insertText', false, replacement)
    area.setSelectionRange(start, start + replacement.length)
  }
  const find = () => {
    const area = input.current
    if (!area || !search) return
    const next = value.indexOf(search, area.selectionEnd)
    const found = next < 0 ? value.indexOf(search) : next
    setSearchResult(found < 0 ? 'No match' : next < 0 ? 'Wrapped to first match' : 'Match selected')
    if (found >= 0) {
      area.focus()
      area.setSelectionRange(found, found + search.length)
      const line = value.slice(0, found).split('\n').length - 1
      area.scrollTop = line * parseFloat(getComputedStyle(area).lineHeight)
      if (ink.current) ink.current.scrollTop = area.scrollTop
      select()
    }
  }
  return <section className="prolog-text" aria-label="Highlighted Prolog editor">
    <div className="prolog-text-tools">
      <label>Find in source <input type="search" value={search} onChange={event => { setSearch(event.target.value); setSearchResult('') }}
        onKeyDown={event => { if (event.key === 'Enter') { event.preventDefault(); find() } }} /></label>
      <button disabled={!search || disabled} onClick={find}>Find next</button>
      <span role="status">{searchResult}</span>
    </div>
    <div className="prolog-text-layers">
      <pre ref={ink} aria-hidden="true">{tokens.map((token, i) => <span key={i} className={`prolog-${token.kind}`}>{token.text}</span>)}{'\n'}</pre>
      <textarea ref={input} aria-label={label} value={value} readOnly={readOnly} disabled={disabled}
        spellCheck={false} autoCapitalize="off" autoCorrect="off" wrap="off" rows={18}
        onSelect={select} onChange={event => onChange(event.target.value)}
        onScroll={event => { if (ink.current) { ink.current.scrollTop = event.currentTarget.scrollTop; ink.current.scrollLeft = event.currentTarget.scrollLeft } }}
        onKeyDown={event => {
          const area = event.currentTarget
          if (event.key === 'f' && (event.ctrlKey || event.metaKey)) {
            event.preventDefault(); area.closest('section')?.querySelector<HTMLInputElement>('input[type="search"]')?.focus()
          }
          if (!readOnly && !disabled && (event.ctrlKey || event.metaKey) && ['[', ']'].includes(event.key)) {
            event.preventDefault(); indent(event.key === '['); return
          }
          if (readOnly || disabled || event.nativeEvent.isComposing || (event.key !== 'Tab' && event.key !== 'Enter')) return
          // Tab retains normal focus traversal. Enter carries indentation
          // through a native edit so undo and input events stay ordinary.
          if (event.key === 'Tab') return
          event.preventDefault()
          const prefix = value.slice(0, area.selectionStart)
          const line = prefix.slice(prefix.lastIndexOf('\n') + 1)
          const indentation = /^\s*/.exec(line)?.[0] ?? ''
          document.execCommand('insertText', false, `\n${indentation}${line.trimEnd().endsWith(':-') ? '    ' : ''}`)
        }} />
    </div>
    <div className="prolog-text-tools"><span>{position}</span>
      {!readOnly && <><button disabled={disabled} onMouseDown={event => event.preventDefault()} onClick={() => indent()}>Indent</button>
        <button disabled={disabled} onMouseDown={event => event.preventDefault()} onClick={() => indent(true)}>Outdent</button></>}
      <span>Enter keeps indentation. Tab moves focus.</span>
    </div>
  </section>
}
