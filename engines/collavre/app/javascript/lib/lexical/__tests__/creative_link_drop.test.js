/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { createEditor, $createParagraphNode, $createTextNode, $getRoot, $setSelection } from 'lexical'
import { registerRichText } from '@lexical/rich-text'
import { $createCodeNode, CodeNode, CodeHighlightNode } from '@lexical/code'
import { LinkNode } from '@lexical/link'
import { CreativeLinkNode } from '../creative_link_node'
import { registerCreativeLinkDrop } from '../creative_link_drop'
import { lexicalToMarkdown } from '../markdown_serialize'
import { createDragDropRegistry } from '../../dnd/registry'
import { ensureDragSessionToken } from '../../dnd/session'
import { getCreativeLabelFromDom } from '../../dnd/creative_label'

let editor, root, cleanup, cleanupRichText
function drag(type, value = { ids: ['12', '34', '12'] }, mime = 'application/x-collavre-creative') {
  if (value.ids) value = { creativeId: value.ids[0], selectedCreativeIds: value.ids, treeId: 'tree', token: ensureDragSessionToken() }
  const event = new DragEvent(type, { bubbles: true, cancelable: true })
  Object.assign(event, { clientX: 10, clientY: 20, dataTransfer: {
    files: [], types: [mime], getData: key => key === mime ? JSON.stringify(value) : '', dropEffect: 'none'
  } })
  root.dispatchEvent(event)
  return event
}

beforeEach(() => {
  globalThis.DragEvent = class extends Event {}
  document.body.innerHTML = '<div id="outer"><div contenteditable="true"></div></div><creative-tree-row creative-id="12"></creative-tree-row>'
  document.querySelector('creative-tree-row').descriptionHtml = '<b>Target &amp; title</b>'
  root = document.querySelector('[contenteditable]')
  editor = createEditor({ namespace: 'drop-test', nodes: [LinkNode, CreativeLinkNode, CodeNode, CodeHighlightNode], onError: error => { throw error } })
  editor.setRootElement(root)
  editor.update(() => {
    const text = $createTextNode('Before after')
    $getRoot().append($createParagraphNode().append(text))
    text.select(7, 7)
  }, { discrete: true })
  cleanupRichText = registerRichText(editor)
  cleanup = registerCreativeLinkDrop(editor)
})
afterEach(() => {
  cleanup()
  cleanupRichText()
  delete globalThis.DragEvent
  editor.setRootElement(null)
  delete document.caretRangeFromPoint
  delete document.caretPositionFromPoint
  document.body.innerHTML = ''
})

test('copies ordered, deduplicated links, preserving surrounding text and blocking tree movement', () => {
  document.caretRangeFromPoint = () => null
  const move = jest.fn()
  const outer = createDragDropRegistry({ root: document.getElementById('outer') })
  outer.registerDropZone({ selector: '#outer', accepts: ['creative'], onDrop: move })
  const over = drag('dragover')
  expect(over.defaultPrevented).toBe(true)
  expect(over.dataTransfer.dropEffect).toBe('copy')
  expect(drag('drop').defaultPrevented).toBe(true)
  expect(lexicalToMarkdown(editor)).toBe('Before [Target & title](/creatives/12) [34](/creatives/34) after')
  expect(root.querySelector('a').dataset.creativeId).toBe('12')
  expect(move).not.toHaveBeenCalled()
  outer.destroy()
})

test.each(['range', 'position'])('inserts at the pointer using the %s caret API', api => {
  const text = root.querySelector('p').firstChild
  if (api === 'range') {
    const range = document.createRange()
    range.setStart(text, 0)
    range.collapse(true)
    document.caretRangeFromPoint = () => range
  } else {
    document.caretPositionFromPoint = () => ({ offsetNode: text, offset: 0 })
  }
  drag('drop', { ids: ['12'] })
  expect(lexicalToMarkdown(editor)).toBe('[Target & title](/creatives/12) Before after')
})

test('falls back to existing caret when hit testing misses or resolves outside the editor', () => {
  document.caretPositionFromPoint = () => null
  document.caretRangeFromPoint = () => document.createRange()
  drag('drop', { ids: ['34'] })
  expect(lexicalToMarkdown(editor)).toBe('Before [34](/creatives/34) after')
})

test('appends when no text selection is available', () => {
  editor.update(() => $setSelection(null), { discrete: true })
  document.caretRangeFromPoint = () => null
  document.caretPositionFromPoint = () => null
  drag('drop', { ids: ['34'] })
  expect(lexicalToMarkdown(editor)).toBe('Before after[34](/creatives/34)')
})

test('does not delete selected text', () => {
  editor.update(() => $getRoot().getFirstChild().getFirstChild().select(7, 12), { discrete: true })
  drag('drop', { ids: ['34'] })
  expect(lexicalToMarkdown(editor)).toBe('Before [34](/creatives/34) after')
})

test.each(['text/plain', 'Files', 'application/x-comment-ids'])('leaves %s drops to their existing handlers', mime => {
  expect(drag('drop', {}, mime).defaultPrevented).toBe(false)
  expect(lexicalToMarkdown(editor)).toBe('Before after')
})

test('ignores malformed creative data and readonly editors', () => {
  drag('drop', {})
  editor.setEditable(false)
  drag('drop')
  expect(lexicalToMarkdown(editor)).toBe('Before after')
})

test('unregisters on root replacement and cleanup', () => {
  const oldRoot = root
  root = document.createElement('div')
  root.setAttribute('contenteditable', 'true')
  document.body.appendChild(root)
  editor.setRootElement(root)
  drag('drop', { ids: ['34'] })
  expect(lexicalToMarkdown(editor)).toContain('[34](/creatives/34)')
  cleanup()
  const before = lexicalToMarkdown(editor)
  drag('drop')
  root = oldRoot
  drag('drop')
  expect(lexicalToMarkdown(editor)).toBe(before)
})

test('extracts labels from property or dataset, with empty and missing row fallbacks', () => {
  const row = document.querySelector('creative-tree-row')
  expect(getCreativeLabelFromDom('12')).toBe('Target & title')
  row.descriptionHtml = ''
  expect(getCreativeLabelFromDom('12')).toBe(null)
  row.dataset.descriptionHtml = '<i>Dataset title</i>'
  expect(getCreativeLabelFromDom('12')).toBe('Dataset title')
  row.dataset.descriptionHtml = '<br>'
  expect(getCreativeLabelFromDom('12')).toBe('')
  expect(getCreativeLabelFromDom('99')).toBe(null)
})


test.each([['12'], ['34'], ['12', '34']])('inserts plain link text in code blocks for %j', (...ids) => {
  editor.update(() => {
    const text = $createTextNode('let a = 1')
    $getRoot().clear().append($createCodeNode('js').append(text))
    text.select(3, 3)
  }, { discrete: true })
  const expected = ids.map(id => `[${id === '12' ? 'Target & title' : id}](/creatives/${id}) `).join('')
  drag('drop', { ids })
  expect(root.querySelector('a')).toBeNull()
  editor.getEditorState().read(() => {
    const code = $getRoot().getFirstChild()
    expect(code.getType()).toBe('code')
    expect(code.getTextContent()).toBe(`let${expected} a = 1`)
    expect(code.getChildren().every(node => ['text', 'code-highlight'].includes(node.getType()))).toBe(true)
  })
  expect(lexicalToMarkdown(editor)).toContain(`let${expected} a = 1`)
})

test('inserts plain link text into an empty code block', () => {
  editor.update(() => {
    const code = $createCodeNode('js')
    $getRoot().clear().append(code)
    code.selectEnd()
  }, { discrete: true })
  drag('drop', { ids: ['34'] })
  expect(root.querySelector('a')).toBeNull()
  expect(root.textContent).toBe('[34](/creatives/34) ')
})
