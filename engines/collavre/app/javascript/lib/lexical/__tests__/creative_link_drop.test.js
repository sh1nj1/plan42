/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { COMMAND_PRIORITY_HIGH, DROP_COMMAND, createEditor, $createParagraphNode, $createTextNode, $getRoot, $setSelection } from 'lexical'
import { registerRichText } from '@lexical/rich-text'
import { $createCodeNode, CodeNode, CodeHighlightNode } from '@lexical/code'
import { LinkNode, AutoLinkNode, $createLinkNode, $createAutoLinkNode, $isLinkNode } from '@lexical/link'
import { MarkNode, $createMarkNode } from '@lexical/mark'
import { $generateHtmlFromNodes } from '@lexical/html'
import { CreativeLinkNode, $createCreativeLinkNode } from '../creative_link_node'
import { registerCreativeLinkDrop } from '../creative_link_drop'
import { lexicalToMarkdown } from '../markdown_serialize'
import { createDragDropRegistry } from '../../dnd/registry'
import { writeDragData } from '../../dnd/envelope'
import { getCreativeLabelFromDom } from '../../dnd/creative_label'

let editor, root, cleanup, cleanupRichText
function drag(type, value = { ids: ['12', '34', '12'] }, mime = 'application/x-collavre-creative') {
  const data = new Map()
  const dataTransfer = {
    files: [], dropEffect: 'none',
    get types() { return [...data.keys()] },
    getData: key => data.get(key) || '',
    setData: (key, value) => data.set(key, value)
  }
  if (value.ids) {
    writeDragData(dataTransfer, { kind: 'creative', ids: value.ids, payload: { treeId: 'tree', ...value.payload } })
  } else {
    dataTransfer.setData(mime, JSON.stringify(value))
  }
  value.beforeDrop?.(dataTransfer)
  const event = new DragEvent(type, { bubbles: true, cancelable: true })
  Object.assign(event, { clientX: 10, clientY: 20, dataTransfer })
  root.dispatchEvent(event)
  return event
}

beforeEach(() => {
  globalThis.DragEvent = class extends Event {}
  document.body.innerHTML = '<div id="outer"><div contenteditable="true"></div></div><creative-tree-row creative-id="12"></creative-tree-row>'
  document.querySelector('creative-tree-row').descriptionHtml = '<b>Target &amp; title</b>'
  root = document.querySelector('[contenteditable]')
  editor = createEditor({ namespace: 'drop-test', nodes: [LinkNode, AutoLinkNode, MarkNode, CreativeLinkNode, CodeNode, CodeHighlightNode], onError: error => { throw error } })
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
  const drop = drag('drop')
  expect(drop.dataTransfer.types).toEqual(expect.arrayContaining(['application/x-collavre-creative', 'text/plain']))
  expect(drop.dataTransfer.getData('text/plain')).toBe(drop.dataTransfer.getData('application/x-collavre-creative'))
  expect(drop.defaultPrevented).toBe(true)
  expect(root.textContent).not.toContain(drop.dataTransfer.getData('text/plain'))
  expect(lexicalToMarkdown(editor)).toBe('Before [Target & title](/creatives/12) [34](/creatives/34) after')
  expect(root.querySelector('a').dataset.creativeId).toBe('12')
  expect(move).not.toHaveBeenCalled()
  outer.destroy()
})

test('Lexical sees the production plain-text payload first without inserting JSON', async () => {
  const lexicalDrop = jest.fn(event => {
    expect(JSON.parse(event.dataTransfer.getData('text/plain')).selectedCreativeIds).toEqual(['12', '34'])
    expect(root.querySelectorAll('a')).toHaveLength(0)
    // Observe Lexical's earlier root listener, then let registerRichText handle it.
    return false
  })
  const unregister = editor.registerCommand(DROP_COMMAND, lexicalDrop, COMMAND_PRIORITY_HIGH)
  try {
    const event = drag('drop')
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(lexicalDrop).toHaveBeenCalledTimes(1)
    expect(event.defaultPrevented).toBe(true)
    expect(root.querySelectorAll('a')).toHaveLength(2)
    expect(root.textContent).toBe('Before Target & title 34 after')
    expect(lexicalToMarkdown(editor)).toBe('Before [Target & title](/creatives/12) [34](/creatives/34) after')
  } finally {
    unregister()
  }
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


test('uses sidebar labels for creatives absent from the center pane', () => {
  document.body.insertAdjacentHTML('beforeend', `
    <div class="creative-workspace-tree-row" data-creative-id="34">
      <button>Toggle</button>
      <a class="creative-workspace-tree-link"> 사이드바 &amp; title </a>
      <span>Progress</span>
    </div>`)
  drag('drop', { ids: ['34'] })
  expect(root.querySelector('a').textContent).toBe('사이드바 & title')
  expect(lexicalToMarkdown(editor)).toBe('Before [사이드바 & title](/creatives/34) after')
})

test('prefers the center description and falls back to sidebar text when unavailable', () => {
  document.body.insertAdjacentHTML('beforeend', `
    <div class="creative-workspace-tree-row" data-creative-id="12">
      <a class="creative-workspace-tree-link">Sidebar title</a>
    </div>`)
  expect(getCreativeLabelFromDom('12')).toBe('Target & title')
  document.querySelector('creative-tree-row').descriptionHtml = ''
  expect(getCreativeLabelFromDom('12')).toBe('Sidebar title')
  document.querySelector('.creative-workspace-tree-link').textContent = '  '
  expect(getCreativeLabelFromDom('12')).toBe('')
  document.querySelector('.creative-workspace-tree-link').remove()
  expect(getCreativeLabelFromDom('12')).toBeNull()
})


test.each(['paragraph', 'code'])('preserves cross-window labels in a %s without source rows', kind => {
  document.body.insertAdjacentHTML('beforeend', `
    <div class="creative-workspace-tree-row" data-creative-id="34">
      <a class="creative-workspace-tree-link">사이드바 &amp; &lt;img&gt;</a>
    </div>`)
  if (kind === 'code') {
    editor.update(() => {
      const code = $createCodeNode('js')
      $getRoot().clear().append(code)
      code.selectEnd()
    }, { discrete: true })
  }
  drag('drop', {
    ids: ['34', '12', '34', '99'],
    payload: { sourceWindowId: 'another-window' },
    beforeDrop: () => {
      document.querySelector('creative-tree-row').remove()
      document.querySelector('.creative-workspace-tree-row').remove()
    }
  })
  if (kind === 'code') {
    expect(root.querySelector('a')).toBeNull()
    expect(root.textContent).toBe('[사이드바 & <img>](/creatives/34) [Target & title](/creatives/12) [99](/creatives/99) ')
  } else {
    expect([...root.querySelectorAll('a')].map(link => link.textContent)).toEqual(['사이드바 & <img>', 'Target & title', '99'])
    expect(root.textContent).toBe('Before 사이드바 & <img> Target & title 99 after')
    expect(root.querySelector('img')).toBeNull()
  }
})

test.each([undefined, null, {}, { 34: 42 }, { 34: '' }])('falls back for absent or invalid carried labels: %j', creativeLabels => {
  drag('drop', {
    ids: ['34'],
    beforeDrop: transfer => {
      const mime = 'application/x-collavre-creative'
      const payload = JSON.parse(transfer.getData(mime))
      payload.creativeLabels = creativeLabels
      transfer.setData(mime, JSON.stringify(payload))
    }
  })
  expect(lexicalToMarkdown(editor)).toBe('Before [34](/creatives/34) after')
})


describe.each([
  ['link', () => $createLinkNode('https://example.com/original')],
  ['autolink', () => $createAutoLinkNode('https://example.com/original')],
  ['creative-link', () => $createCreativeLinkNode('/creatives/99', '99')]
])('dropping into an existing %s', (_kind, createLink) => {
  test.each([0, 3, 8])('splits at offset %i without nested links in state or exported HTML', async offset => {
    editor.update(() => {
      const text = $createTextNode('original')
      $getRoot().clear().append($createParagraphNode().append(
        $createTextNode('Before '), createLink().append(text), $createTextNode(' after')
      ))
      text.select(0, 0)
    }, { discrete: true })
    const range = document.createRange()
    range.setStart(root.querySelector('a span').firstChild, offset)
    range.collapse(true)
    document.caretRangeFromPoint = () => range

    const event = drag('drop')
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(event.defaultPrevented).toBe(true)
    expect(root.textContent).toBe(`Before ${'original'.slice(0, offset)}Target & title 34 ${'original'.slice(offset)} after`)
    expect(root.querySelector('a a')).toBeNull()
    expect([...root.querySelectorAll('a[data-creative-id]')]
      .filter(link => link.dataset.creativeId !== '99')
      .map(link => [link.getAttribute('href'), link.textContent]))
      .toEqual([['/creatives/12', 'Target & title'], ['/creatives/34', '34']])
    editor.getEditorState().read(() => {
      const paragraph = $getRoot().getFirstChild()
      const links = paragraph.getChildren().filter($isLinkNode)
      expect(links.filter(link => ['/creatives/12', '/creatives/34'].includes(link.getURL()))).toHaveLength(2)
      for (const link of links) {
        expect(link.getChildrenSize()).toBeGreaterThan(0)
        expect(link.getTextContent()).not.toBe('')
        expect(link.getChildren().every(child => !$isLinkNode(child))).toBe(true)
      }
      expect(links.filter(link => !['/creatives/12', '/creatives/34'].includes(link.getURL()))
        .map(link => link.getTextContent()).join('')).toBe('original')
      const exported = new DOMParser().parseFromString($generateHtmlFromNodes(editor), 'text/html')
      expect(exported.querySelector('a a')).toBeNull()
      expect(exported.body.textContent).toBe(root.textContent)
      expect(exported.querySelectorAll('a').length).toBe(links.length)
      expect([...exported.querySelectorAll('a')].every(link => link.textContent.length > 0)).toBe(true)
    })
    expect(lexicalToMarkdown(editor)).not.toContain('[](')
  })
})


test.each(['element', 'nested', 'text-end', 'text-start'])('splits a link with a %s caret', kind => {
  editor.update(() => {
    const text = $createTextNode('original')
    const link = $createLinkNode('https://example.com/original')
    link.append(kind === 'nested' ? $createMarkNode(['annotation']).append(text) : text)
    $getRoot().clear().append($createParagraphNode().append(link, $createTextNode(' after')))
    if (kind === 'element') link.select(0, 0)
    else if (kind === 'text-start') text.select(0, 0)
    else if (kind === 'text-end') text.select(8, 8)
    else text.select(3, 3)
  }, { discrete: true })
  drag('drop', { ids: ['34'] })
  expect(root.querySelector('a a')).toBeNull()
  expect(root.textContent).toBe({ element: '34 original after', nested: 'ori34 ginal after', 'text-end': 'original34  after', 'text-start': '34 original after' }[kind])
  expect(root.querySelector('a[data-creative-id="34"]').parentElement.tagName).toBe('P')
})


describe.each([
  ['link', () => $createLinkNode('https://example.com/original')],
  ['autolink', () => $createAutoLinkNode('https://example.com/original')],
  ['creative-link', () => $createCreativeLinkNode('/creatives/99', '99')]
])('dropping at %s boundaries', (_kind, createLink) => {
  test.each(['text', 'element', 'marked-text', 'marked-element'])('keeps no empty wrappers for a %s caret', kind => {
    for (const end of [false, true]) {
      editor.update(() => {
        const text = $createTextNode('original')
        const mark = $createMarkNode(['annotation']).append(text)
        const link = createLink().append(kind.startsWith('marked') ? mark : text)
        $getRoot().clear().append($createParagraphNode().append(
          $createTextNode('Before '), link, $createTextNode(' after')
        ))
        const anchor = kind === 'element' ? link : kind === 'marked-element' ? mark : text
        const offset = end ? (kind.endsWith('element') ? 1 : 8) : 0
        anchor.select(offset, offset)
      }, { discrete: true })
      drag('drop', { ids: ['34'] })
      expect(root.textContent).toBe(end ? 'Before original34  after' : 'Before 34 original after')
      expect(lexicalToMarkdown(editor)).not.toContain('[](')
      editor.getEditorState().read(() => {
        const paragraph = $getRoot().getFirstChild()
        const links = paragraph.getChildren().filter($isLinkNode)
        expect(links).toHaveLength(2)
        expect(links.map(link => link.getTextContent())).toEqual(end ? ['original', '34'] : ['34', 'original'])
        for (const link of links) {
          expect(link.getChildrenSize()).toBeGreaterThan(0)
          for (const child of link.getChildren()) {
            if (child instanceof MarkNode) {
              expect(child.getChildrenSize()).toBeGreaterThan(0)
              expect(child.getIDs()).toEqual(['annotation'])
            }
          }
        }
        const exported = new DOMParser().parseFromString($generateHtmlFromNodes(editor), 'text/html')
        expect(exported.querySelector('a a')).toBeNull()
        expect([...exported.querySelectorAll('a')].map(link => link.textContent)).toEqual(end ? ['original', '34'] : ['34', 'original'])
      })
    }
  })
})
