import { openingFocusOptions } from '../popup_focus'
import { focusWhenAvailable } from '../../../lib/utils/focus'

const originalRAF = global.requestAnimationFrame
let frames
beforeEach(() => {
  frames = []
  global.requestAnimationFrame = callback => { frames.push(callback) }
})
afterEach(() => {
  document.body.innerHTML = ''
  global.requestAnimationFrame = originalRAF
})

function controls() {
  const opener = document.createElement('button')
  const previous = document.createElement('a')
  previous.href = '#'
  const other = document.createElement('button')
  const textarea = document.createElement('textarea')
  document.body.append(opener, previous, other, textarea)
  return { opener, previous, other, textarea }
}

test('programmatic opens do not exempt the active control', () => {
  const { previous, textarea } = controls()
  previous.focus()
  expect(openingFocusOptions(null)).toEqual({})
  focusWhenAvailable(textarea, openingFocusOptions(null))
  frames.shift()()
  expect(document.activeElement).toBe(previous)
})

test.each(['opener', 'previous'])('click autofocus allows unchanged %s focus', focused => {
  const elements = controls()
  elements[focused].focus()
  const options = openingFocusOptions(elements.opener)
  focusWhenAvailable(elements.textarea, options)
  frames.shift()()
  expect(document.activeElement).toBe(elements.textarea)
})

test('focus moved while loading remains protected when the click does not focus the opener', () => {
  const { opener, previous, other, textarea } = controls()
  previous.focus()
  const options = openingFocusOptions(opener)
  other.focus()
  focusWhenAvailable(textarea, options)
  frames.shift()()
  expect(document.activeElement).toBe(other)
})

test('an open editor remains protected even when its focus predates the click', () => {
  const { opener, textarea } = controls()
  const editor = document.createElement('input')
  editor.id = 'inline-edit-form'
  document.body.append(editor)
  editor.focus()
  focusWhenAvailable(textarea, openingFocusOptions(opener))
  frames.shift()()
  expect(document.activeElement).toBe(editor)
})

test('another text input remains protected during click-open', () => {
  const { opener, textarea } = controls()
  const input = document.createElement('input')
  document.body.append(input)
  input.focus()
  focusWhenAvailable(textarea, openingFocusOptions(opener))
  frames.shift()()
  expect(document.activeElement).toBe(input)
})
