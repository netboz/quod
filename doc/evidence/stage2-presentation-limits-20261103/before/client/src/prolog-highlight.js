// Presentation tokens only. The owning server parser validates executable text.
// Every input byte stays in the token stream, including incomplete drafts.
const lexical = /(?<comment>%[^\n]*|\/\*[\s\S]*?(?:\*\/|$))|(?<literal><<"(?:\\(?:x[0-9a-fA-F]+\\|[\s\S])|[^"\\])*"?>>?|"(?:\\(?:x[0-9a-fA-F]+\\|[\s\S])|[^"\\])*"?|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(?<atom>'(?:\\(?:x[0-9a-fA-F]+\\|[\s\S])|[^'\\])*'?|[a-z][a-zA-Z0-9_]*)|(?<variable>[A-Z_][a-zA-Z0-9_]*)|(?<operator>:-|::|[#$&*+\-./:<=>?@\\^~;!]+)|(?<space>\s+)|(?<punctuation>[\s\S])/g

export function highlightProlog(source) {
  const tokens = [...source.matchAll(lexical)].map(match => {
    const kind = Object.keys(match.groups).find(key => match.groups[key] !== undefined)
    return { text: match[0], kind: kind === 'atom' && match[0].startsWith("'") ? 'quoted' : kind }
  })
  const code = tokens.filter(token => token.kind !== 'space' && token.kind !== 'comment')
  let head = 0
  for (let i = 0; i < code.length; i++) {
    const token = code[i]
    if (token.text === '.') {
      if (['atom', 'quoted'].includes(code[head]?.kind)) {
        const clause = code.slice(head, i)
        const separator = clause.findIndex(t => t.text === ':-')
        const fact = separator < 0 || (clause.length === separator + 2 && clause.at(-1).text === 'true')
        code[head].kind = fact ? 'fact' : 'rule'
      }
      head = i + 1
    }
    if (token.text === ':' || token.text === '::') {
      if (['atom', 'quoted', 'literal'].includes(code[i - 1]?.kind)) code[i - 1].kind = 'namespace'
      if (token.text === '::' && ['atom', 'quoted'].includes(code[i + 1]?.kind)) code[i + 1].kind = 'qualified'
    }
  }
  return tokens
}
