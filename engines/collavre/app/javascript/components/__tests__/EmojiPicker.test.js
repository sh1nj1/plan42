/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { act, createElement as h } from 'react'
import { createRoot } from 'react-dom/client'
import { fireEvent, getByRole, queryByRole } from '@testing-library/dom'
import { $createParagraphNode, $createTextNode, $getRoot, $setSelection, createEditor } from 'lexical'
import EmojiPicker from '../EmojiPicker'

let host, root, editor, editable
beforeEach(() => {
  globalThis.IS_REACT_ACT_ENVIRONMENT = true
  host = document.createElement('div')
  editable = document.createElement('div')
  editable.contentEditable = true
  document.body.append(host, editable)
  editor = createEditor({ namespace: 'emoji-test', onError: (error) => { throw error } })
  editor.setRootElement(editable)
  editor.update(() => {
    const text = $createTextNode('Hello world')
    $getRoot().append($createParagraphNode().append(text))
    text.select(6, 11)
  }, { discrete: true })
  root = createRoot(host)
  act(() => root.render(h(EmojiPicker, { editor, label: '이모지 삽입' })))
})
afterEach(() => {
  act(() => root.unmount())
  editor.setRootElement(null)
  document.body.replaceChildren()
})
const trigger = () => getByRole(host, 'button', { name: '이모지 삽입' })
const open = () => act(() => fireEvent.click(trigger()))
const text = () => editor.getEditorState().read(() => $getRoot().getTextContent())

test('opens a labeled popup, focuses an emoji, and toggles closed', () => {
  expect(trigger().getAttribute('aria-expanded')).toBe('false')
  expect(fireEvent.mouseDown(trigger())).toBe(false)
  open()
  expect(getByRole(host, 'dialog').getAttribute('aria-label')).toBe('이모지 삽입')
  expect(document.activeElement.textContent).toBe('😀')
  expect(trigger().getAttribute('aria-expanded')).toBe('true')
  open()
  expect(queryByRole(host, 'dialog')).toBeNull()
})
test('restores the saved range and replaces selected text with a complete emoji', async () => {
  open()
  editor.update(() => $getRoot().selectStart(), { discrete: true })
  await act(async () => fireEvent.click(getByRole(host, 'button', { name: '❤️' })))
  expect(text()).toBe('Hello ❤️')
  expect(queryByRole(host, 'dialog')).toBeNull()
})
test('inserts at the caret', async () => {
  editor.update(() => $getRoot().getFirstChild().getFirstChild().select(5, 5), { discrete: true })
  open()
  await act(async () => fireEvent.click(getByRole(host, 'button', { name: '🎉' })))
  expect(text()).toBe('Hello🎉 world')
})
test('inserts at the end when there is no selection', async () => {
  editor.update(() => $setSelection(null), { discrete: true })
  open()
  await act(async () => fireEvent.click(getByRole(host, 'button', { name: '👍' })))
  expect(text()).toBe('Hello world👍')
})
test('outside click dismisses without changing content; inside click does not dismiss', () => {
  open()
  act(() => fireEvent.mouseDown(getByRole(host, 'dialog')))
  expect(queryByRole(host, 'dialog')).not.toBeNull()
  act(() => fireEvent.mouseDown(document.body))
  expect(queryByRole(host, 'dialog')).toBeNull()
  expect(text()).toBe('Hello world')
})
test('Escape closes only the popup and returns focus to its trigger', () => {
  open()
  act(() => fireEvent.keyDown(document.activeElement, { key: 'Tab' }))
  expect(queryByRole(host, 'dialog')).not.toBeNull()
  let bubbled = false
  const listener = () => { bubbled = true }
  document.addEventListener('keydown', listener)
  act(() => fireEvent.keyDown(document.activeElement, { key: 'Escape' }))
  document.removeEventListener('keydown', listener)
  expect(bubbled).toBe(false)
  expect(queryByRole(host, 'dialog')).toBeNull()
  expect(document.activeElement).toBe(trigger())
})
test('unmount while open removes document listeners', () => {
  open()
  act(() => root.unmount())
  root = createRoot(host)
  expect(() => fireEvent.keyDown(document, { key: 'Escape' })).not.toThrow()
  expect(() => fireEvent.mouseDown(document.body)).not.toThrow()
})

test.each(['🔖', '📚', '🗂️', '🔍'])('inserts the added emoji %s from a complete seven-row grid', async (emoji) => {
  open()
  expect(getByRole(host, 'dialog').querySelectorAll('button')).toHaveLength(56)
  await act(async () => fireEvent.click(getByRole(host, 'button', { name: emoji })))
  expect(text()).toBe(`Hello ${emoji}`)
})

test('clamps an indented popup and repositions on resize and scroll', () => {
  let anchorLeft = 200
  let viewportWidth = 375
  const viewport = jest.spyOn(document.documentElement, 'clientWidth', 'get').mockImplementation(() => viewportWidth)
  const bounds = jest.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function () {
    return { left: anchorLeft, width: this.classList.contains('lexical-emoji-picker__popup') ? 300 : 28 }
  })
  try {
    open()
    const popup = getByRole(host, 'dialog')
    expect(popup.style.left).toBe('-133px')
    viewportWidth = 1024
    fireEvent(window, new Event('resize'))
    expect(popup.style.left).toBe('0px')
    anchorLeft = -20
    fireEvent.scroll(document)
    expect(popup.style.left).toBe('28px')
    open()
    fireEvent(window, new Event('resize'))
    fireEvent.scroll(document)
    expect(queryByRole(host, 'dialog')).toBeNull()
  } finally {
    viewport.mockRestore()
    bounds.mockRestore()
  }
})
