/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const { default: SearchPopupController } = await import('../search_popup_controller')

describe('SearchPopupController Ctrl+K shortcut', () => {
  let application
  let container
  let popup

  function pressCtrlK(target) {
    const event = new KeyboardEvent('keydown', {
      key: 'k',
      ctrlKey: true,
      bubbles: true,
      cancelable: true
    })
    target.dispatchEvent(event)
    return event
  }

  beforeEach(async () => {
    document.body.innerHTML = ''

    container = document.createElement('div')
    container.innerHTML = `
      <div data-controller="search-popup">
        <input type="text" data-search-popup-target="input" />
        <div data-search-popup-target="popup"></div>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('search-popup', SearchPopupController)
    await new Promise(resolve => setTimeout(resolve, 0))

    popup = container.querySelector('[data-search-popup-target="popup"]')
  })

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('opens the popup on Ctrl+K when focus is not in an editable element', () => {
    const event = pressCtrlK(document.body)

    expect(popup.classList.contains('open')).toBe(true)
    expect(event.defaultPrevented).toBe(true)
  })

  test('does not open the popup when Ctrl+K is pressed inside a text input', () => {
    const input = document.createElement('input')
    input.type = 'text'
    document.body.appendChild(input)
    input.focus()

    const event = pressCtrlK(input)

    expect(popup.classList.contains('open')).toBe(false)
    expect(event.defaultPrevented).toBe(false)
  })

  test('does not open the popup when Ctrl+K is pressed inside a textarea', () => {
    const textarea = document.createElement('textarea')
    document.body.appendChild(textarea)
    textarea.focus()

    const event = pressCtrlK(textarea)

    expect(popup.classList.contains('open')).toBe(false)
    expect(event.defaultPrevented).toBe(false)
  })

  test('does not open the popup when Ctrl+K is pressed inside a contenteditable element', () => {
    const editable = document.createElement('div')
    editable.setAttribute('contenteditable', 'true')
    document.body.appendChild(editable)
    editable.focus()

    const event = pressCtrlK(editable)

    expect(popup.classList.contains('open')).toBe(false)
    expect(event.defaultPrevented).toBe(false)
  })

  test('does not open the popup when Ctrl+K is pressed inside the inline Lexical editor', () => {
    const lexicalRoot = document.createElement('div')
    lexicalRoot.setAttribute('data-lexical-editor-root', '')
    const inner = document.createElement('p')
    lexicalRoot.appendChild(inner)
    document.body.appendChild(lexicalRoot)

    const event = pressCtrlK(inner)

    expect(popup.classList.contains('open')).toBe(false)
    expect(event.defaultPrevented).toBe(false)
  })
})
