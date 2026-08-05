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

describe('SearchPopupController filter persistence', () => {
  const STORAGE_KEY = 'collavre.creativeSearchFilters'
  const FILTER_KEYS = [
    'tags', 'min_progress', 'max_progress', 'search', 'comment',
    'has_comments', 'due_before', 'due_after', 'has_due_date',
    'assignee_id', 'unassigned', 'show_archived'
  ]

  let application
  let visitSpy
  let replaceSpy

  // jsdom's window.location is non-configurable, so read-state (pathname/search)
  // is arranged via history.pushState (which jsdom reflects into location), and
  // the navigation seams are spied on the prototype so connect-time restore is
  // captured too.
  function setUrl(path) {
    window.history.pushState({}, '', path)
  }

  // Mounts the controller (which runs connect → restore) after URL and storage
  // have been arranged, and returns the controller instance.
  async function mount() {
    const container = document.createElement('div')
    container.innerHTML = `
      <div data-controller="search-popup"
           data-search-popup-index-path-value="/creatives"
           data-search-popup-filter-keys-value='${JSON.stringify(FILTER_KEYS)}'>
        <input type="text" data-search-popup-target="input" />
        <div data-search-popup-target="popup"></div>
      </div>
    `
    document.body.appendChild(container)

    application = Application.start()
    application.register('search-popup', SearchPopupController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    const element = container.querySelector('[data-controller="search-popup"]')
    return application.getControllerForElementAndIdentifier(element, 'search-popup')
  }

  beforeEach(() => {
    document.body.innerHTML = ''
    window.localStorage.clear()
    visitSpy = jest
      .spyOn(SearchPopupController.prototype, '_visit')
      .mockImplementation(() => {})
    replaceSpy = jest
      .spyOn(SearchPopupController.prototype, '_replaceWith')
      .mockImplementation(() => {})
  })

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ''
    window.history.pushState({}, '', '/')
    jest.restoreAllMocks()
  })

  test('persists the filter set to localStorage when a filter is applied', async () => {
    setUrl('/creatives')
    const controller = await mount()

    controller.applyCommentFilter({ preventDefault() {} })

    expect(JSON.parse(window.localStorage.getItem(STORAGE_KEY))).toEqual({ comment: 'true' })
    expect(visitSpy).toHaveBeenCalledWith('/creatives?comment=true')
  })

  test('restores persisted filters on a bare index view via replace', async () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ search: 'hello' }))
    setUrl('/creatives')

    await mount()

    expect(replaceSpy).toHaveBeenCalledWith('/creatives?search=hello')
  })

  test('does not restore when the URL already carries a filter param', async () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ search: 'hello' }))
    setUrl('/creatives?search=world')

    await mount()

    expect(replaceSpy).not.toHaveBeenCalled()
  })

  test('does not restore when drilling into a subtree (id param present)', async () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ search: 'hello' }))
    setUrl('/creatives?id=42')

    await mount()

    expect(replaceSpy).not.toHaveBeenCalled()
  })

  test('clearing the last filter removes the stored set (no resurrection)', async () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ search: 'x' }))
    setUrl('/creatives?search=x')
    const controller = await mount()

    // Emptying the search input and submitting clears the only active filter.
    controller.inputTarget.value = ''
    controller.submitSearch({ key: 'Enter', preventDefault() {} })

    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull()
    expect(visitSpy).toHaveBeenCalledWith('/creatives')
  })

  test('reset clears storage and navigates to the unfiltered index', async () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ search: 'x' }))
    setUrl('/creatives?search=x')
    const controller = await mount()

    controller.reset({ preventDefault() {} })

    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull()
    expect(visitSpy).toHaveBeenCalledWith('/creatives')
  })
})
