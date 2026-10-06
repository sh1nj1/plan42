/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { focusWhenAvailable } from '../focus'

describe('focusWhenAvailable', () => {
  let target, frames
  beforeEach(() => {
    document.body.innerHTML = '<div id="popup"><textarea id="chat"></textarea></div>'
    target = document.getElementById('chat')
    frames = []
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => frames.push(callback))
  })
  afterEach(() => {
    document.dispatchEvent(new CustomEvent('creative-editing:stop'))
    jest.restoreAllMocks()
    document.body.innerHTML = ''
  })
  const flush = () => frames.splice(0).forEach(callback => callback())

  test('focuses an available input and preserves its existing selection', () => {
    target.value = 'hello'
    target.setSelectionRange(2, 2)
    focusWhenAvailable(target)
    flush()
    expect(document.activeElement).toBe(target)
    focusWhenAvailable(target)
    flush()
    expect(target.selectionStart).toBe(2)
  })

  test.each(['input', 'textarea', 'select', 'div contenteditable="true"', 'div contenteditable=""', 'div contenteditable="plaintext-only"'])(
    'does not steal focus from %s', markup => {
      const other = document.createElement('div')
      other.innerHTML = `<${markup} tabindex="0"></${markup.split(' ')[0]}>`
      document.body.append(other)
      focusWhenAvailable(target)
      other.firstElementChild.focus()
      flush()
      expect(document.activeElement).toBe(other.firstElementChild)
    })

  test.each(['<button>Move</button>', '<a href="#">Move</a>', '<div tabindex="0">Move</div>', '<div tabindex="-1">Move</div>'])(
    'protects keyboard navigation on %s', markup => {
      document.body.insertAdjacentHTML('beforeend', markup)
      const action = document.body.lastElementChild
      focusWhenAvailable(target)
      action.focus()
      flush()
      expect(document.activeElement).toBe(action)
      focusWhenAvailable(target, { explicit: true })
      expect(document.activeElement).toBe(target)
    })

  test('protects a focused descendant of a rich text editor', () => {
    document.body.insertAdjacentHTML('beforeend', '<div contenteditable="true"><span tabindex="0">text</span></div>')
    const span = document.querySelector('span')
    span.focus()
    focusWhenAvailable(target)
    flush()
    expect(document.activeElement).toBe(span)
  })

  test('protects an open creative editor even when focus is on body', () => {
    focusWhenAvailable(target)
    document.body.insertAdjacentHTML('beforeend', '<div id="inline-edit-form" style="display:block"></div>')
    flush()
    expect(document.activeElement).toBe(document.body)
  })

  test.each(['creative-editing:stop', 'turbo:before-cache', 'workspace replacement'])(
    'protects a hidden editor until %s releases it', release => {
      document.body.insertAdjacentHTML('beforeend', '<div id="inline-edit-form"></div>')
      const editor = document.getElementById('inline-edit-form')
      document.dispatchEvent(new CustomEvent('creative-editing:start'))
      editor.style.display = 'none'
      focusWhenAvailable(target)
      flush()
      expect(document.activeElement).toBe(document.body)
      if (release === 'workspace replacement') editor.remove()
      else document.dispatchEvent(new CustomEvent(release))
      focusWhenAvailable(target)
      flush()
      expect(document.activeElement).toBe(target)
    })

  test('allows focus after the creative editor closes', () => {
    document.body.insertAdjacentHTML('beforeend', '<div id="inline-edit-form" style="display:none"></div>')
    focusWhenAvailable(target)
    flush()
    expect(document.activeElement).toBe(target)
  })

  test('allows explicit user actions while another editor is active', () => {
    document.body.insertAdjacentHTML('beforeend', '<div id="inline-edit-form"><input></div>')
    document.querySelector('input').focus()
    focusWhenAvailable(target, { explicit: true })
    expect(document.activeElement).toBe(target)
  })

  test('explicit focus still respects hidden forms', () => {
    target.parentElement.hidden = true
    focusWhenAvailable(target, { explicit: true })
    expect(document.activeElement).toBe(document.body)
  })

  test.each(['display', 'visibility', 'hidden', 'inert', 'removed', 'disabled'])(
    'ignores a target that becomes unavailable: %s', state => {
      const focus = jest.spyOn(target, 'focus')
      focusWhenAvailable(target)
      const popup = target.parentElement
      if (state === 'display') popup.style.display = 'none'
      if (state === 'visibility') popup.style.visibility = 'hidden'
      if (state === 'hidden') popup.hidden = true
      if (state === 'inert') popup.inert = true
      if (state === 'removed') popup.remove()
      if (state === 'disabled') target.disabled = true
      flush()
      expect(focus).not.toHaveBeenCalled()
    })

  test('ignores a missing target', () => {
    focusWhenAvailable(null)
    expect(flush).not.toThrow()
  })
})
