/** @jest-environment jsdom */
import { act, createElement as h } from 'react'
import { createRoot } from 'react-dom/client'
import { fireEvent, getByRole } from '@testing-library/dom'
import { createEditor, $getRoot, $createParagraphNode, $createTextNode, $setSelection, SELECTION_CHANGE_COMMAND } from 'lexical'
import { HeadingNode, registerRichText } from '@lexical/rich-text'
import { CodeNode } from '@lexical/code'
import { ListNode, ListItemNode } from '@lexical/list'
import { registerMarkdownShortcuts, $convertToMarkdownString, HEADING } from '@lexical/markdown'
import HeadingButtons from '../HeadingButtons'
import { CREATIVE_MARKDOWN_TRANSFORMERS } from '../plugins/markdown_shortcuts_plugin'

let editor, host, root, editable, cleanup
beforeEach(() => {
  globalThis.IS_REACT_ACT_ENVIRONMENT = true
  host = document.createElement('div')
  editable = document.createElement('div')
  editable.contentEditable = true
  document.body.append(host, editable)
  editor = createEditor({ namespace: 'headings', nodes: [HeadingNode, CodeNode, ListNode, ListItemNode], onError: error => { throw error } })
  editor.setRootElement(editable)
  cleanup = registerRichText(editor)
  editor.update(() => {
    const text = $createTextNode('Title').toggleFormat('bold')
    $getRoot().append($createParagraphNode().append(text))
    text.selectEnd()
  }, { discrete: true })
  root = createRoot(host)
  act(() => root.render(h(HeadingButtons, { editor, labels: ['제목 1', '제목 2', '제목 3'] })))
})
afterEach(() => {
  act(() => root.unmount())
  cleanup()
  editor.setRootElement(null)
  document.body.replaceChildren()
  delete globalThis.IS_REACT_ACT_ENVIRONMENT
})
const button = level => getByRole(host, 'button', { name: `제목 ${level}` })
const click = async level => act(async () => fireEvent.click(button(level)))
const read = fn => editor.getEditorState().read(fn)

test.each([1, 2, 3])('toggles H%i, preserving text, formatting and selection', async level => {
  expect(fireEvent.mouseDown(button(level))).toBe(false)
  await click(level)
  read(() => {
    const heading = $getRoot().getFirstChild()
    expect(heading.getTag()).toBe(`h${level}`)
    expect(heading.getTextContent()).toBe('Title')
    expect(heading.getFirstChild().hasFormat('bold')).toBe(true)
    expect($convertToMarkdownString([HEADING])).toBe(`${'#'.repeat(level)} Title`)
  })
  expect(button(level).getAttribute('aria-pressed')).toBe('true')
  await click(level)
  expect(read(() => $getRoot().getFirstChild().getType())).toBe('paragraph')
  expect(button(level).getAttribute('aria-pressed')).toBe('false')
})

test('switches heading levels and refreshes when selection changes', async () => {
  await click(1)
  await click(3)
  expect(button(1).getAttribute('aria-pressed')).toBe('false')
  expect(button(3).getAttribute('aria-pressed')).toBe('true')
  act(() => editor.update(() => {
    $getRoot().append($createParagraphNode())
    $getRoot().getLastChild().select()
    editor.dispatchCommand(SELECTION_CHANGE_COMMAND)
  }, { discrete: true }))
  expect(button(3).getAttribute('aria-pressed')).toBe('false')
})

test('does nothing without a range selection', async () => {
  act(() => editor.update(() => $setSelection(null), { discrete: true }))
  await click(2)
  expect(read(() => $getRoot().getFirstChild().getType())).toBe('paragraph')
})

test('formats all selected paragraphs without losing content', async () => {
  act(() => editor.update(() => {
    $getRoot().append($createParagraphNode().append($createTextNode('Second')))
    $getRoot().select(0, 2)
  }, { discrete: true }))
  await click(2)
  expect(read(() => $getRoot().getChildren().map(node => [node.getTag(), node.getTextContent()]))).toEqual([['h2', 'Title'], ['h2', 'Second']])
})

test.each([[1, '#'], [2, '##'], [3, '###'], [null, '####'], [null, 'text #']])('typing %s / %s then space transforms only supported prefixes', async (level, prefix) => {
  const unregister = registerMarkdownShortcuts(editor, CREATIVE_MARKDOWN_TRANSFORMERS)
  act(() => editor.update(() => {
    $getRoot().clear().append($createParagraphNode().append($createTextNode(prefix)))
    $getRoot().getFirstChild().getFirstChild().selectEnd()
  }, { discrete: true }))
  await act(async () => editor.update(() => {
    const text = $getRoot().getFirstChild().getFirstChild()
    text.setTextContent(prefix + ' ')
    text.selectEnd()
  }, { discrete: true }))
  read(() => {
    const block = $getRoot().getFirstChild()
    expect(block.getType()).toBe(level ? 'heading' : 'paragraph')
    if (level) {
      expect(block.getTag()).toBe(`h${level}`)
      expect(block.getTextContent()).toBe('')
    } else expect(block.getTextContent()).toBe(prefix + ' ')
  })
  unregister()
})

test('renders semantic heading symbols when optional labels are absent', () => {
  act(() => root.render(h(HeadingButtons, { editor })))
  expect(getByRole(host, 'button', { name: 'H1' })).toBeTruthy()
})
