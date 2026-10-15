import test from 'node:test'
import assert from 'node:assert/strict'
import { highlightProlog } from '../src/prolog-highlight.js'

test('highlights Quod clauses without interpreting or rewriting source', () => {
  const source = `% A draft with Customer's own name\nprice(12.5).\neligible(Customer) :- quod:accounts::member(Customer), label(<<"a.%\\xA\\">>), tag('two words').\n/* incomplete comment`
  const tokens = highlightProlog(source)
  assert.equal(tokens.map(t => t.text).join(''), source)
  const kinds = text => tokens.filter(t => t.text === text).map(t => t.kind)
  assert.deepEqual(kinds('price'), ['fact'])
  assert.deepEqual(kinds('eligible'), ['rule'])
  assert.deepEqual(kinds('Customer'), ['variable', 'variable'])
  assert.deepEqual(kinds('12.5'), ['literal'])
  assert.deepEqual(kinds("'two words'"), ['quoted'])
  assert.deepEqual(kinds('quod'), ['namespace'])
  assert.deepEqual(kinds('accounts'), ['namespace'])
  assert.deepEqual(kinds('member'), ['qualified'])
  assert.equal(tokens.at(-1).kind, 'comment')
})

test('HTML and unfinished quoted drafts remain inert text', () => {
  for (const source of [`p(<<"<script>alert(1)</script>">>).`, `p('an unfinished atom`, `p("line\nbreak`, '', 'p(X).\nq(Y) :- p(Y).']) {
    assert.equal(highlightProlog(source).map(t => t.text).join(''), source)
  }
})

test('canonical stored facts retain fact highlighting', () => {
  const tokens = highlightProlog('stored(value) :- true.\nrule(X) :- stored(X).')
  assert.equal(tokens.find(t => t.text === 'stored').kind, 'fact')
  assert.equal(tokens.find(t => t.text === 'rule').kind, 'rule')
})
