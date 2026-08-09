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

const WORKSPACE_FRAME_ID = 'creative-workspace-content'

describe('SearchPopupController filter navigation', () => {
  let application
  let visit
  let popup

  // jsdom's window.location is unforgeable, so drive it through history.
  function setLocation(href) {
    window.history.replaceState({}, '', href)
  }

  async function mount({ onIndex = true, withFrame = true } = {}) {
    document.body.innerHTML = `
      ${withFrame ? `<turbo-frame id="${WORKSPACE_FRAME_ID}"></turbo-frame>` : ''}
      <div data-controller="search-popup"
           data-search-popup-index-path-value="/creatives"
           data-search-popup-on-index-value="${onIndex}">
        <button data-filter-state="any-filter"></button>
        <input type="text" data-search-popup-target="input"
               data-action="keydown->search-popup#submitSearch" />
        <div data-search-popup-target="popup" class="open"></div>
        <button data-filter="all" data-filter-state="progress:all"
                data-action="click->search-popup#applyProgressFilter"></button>
        <button data-filter="incomplete" data-filter-state="progress:incomplete"
                data-action="click->search-popup#applyProgressFilter"></button>
        <button data-filter-state="comment"
                data-action="click->search-popup#applyCommentFilter"></button>
        <button data-filter-state="archived"
                data-label-on="Hide archived" data-label-off="Show archived"
                data-action="click->search-popup#toggleArchive">Show archived</button>
        <button data-mode="tree" data-action="click->search-popup#applySearchMode"></button>
        <button data-mode="flat" data-action="click->search-popup#applySearchMode"></button>
      </div>
    `

    application = Application.start()
    application.register('search-popup', SearchPopupController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    popup = document.querySelector('[data-search-popup-target="popup"]')
  }

  function click(selector) {
    document.querySelector(selector).click()
  }

  beforeEach(() => {
    visit = jest.fn()
    window.Turbo = { visit }
    setLocation('http://localhost/creatives')
  })

  afterEach(() => {
    application?.stop()
    application = null
    delete window.Turbo
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('applies a progress filter through the workspace frame', async () => {
    await mount()

    click('[data-filter="incomplete"]')

    expect(visit).toHaveBeenCalledWith('/creatives?min_progress=0&max_progress=0.99', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
  })

  test('applies the comment filter through the workspace frame', async () => {
    await mount()

    click('[data-filter-state="comment"]')

    expect(visit).toHaveBeenCalledWith('/creatives?comment=true', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
  })

  test('toggles the archive filter and swaps its label', async () => {
    await mount()

    click('[data-filter-state="archived"]')

    expect(visit).toHaveBeenCalledWith('/creatives?show_archived=true', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
    expect(document.querySelector('[data-filter-state="archived"]').textContent).toBe(
      'Hide archived'
    )
  })

  test('toggles the archive filter back off', async () => {
    setLocation('http://localhost/creatives?show_archived=true')
    await mount()

    click('[data-filter-state="archived"]')

    expect(visit).toHaveBeenCalledWith('/creatives', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
  })

  test('applies the tree search mode', async () => {
    await mount()

    click('[data-mode="tree"]')

    expect(visit).toHaveBeenCalledWith('/creatives?search_mode=tree', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
  })

  test('drops the search mode param when returning to flat mode', async () => {
    setLocation('http://localhost/creatives?search_mode=tree')
    await mount()

    click('[data-mode="flat"]')

    expect(visit).toHaveBeenCalledWith('/creatives', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
  })

  test('submits the search term on Enter', async () => {
    await mount()
    const input = document.querySelector('[data-search-popup-target="input"]')
    input.value = 'roadmap'

    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })
    )

    expect(visit).toHaveBeenCalledWith('/creatives?search=roadmap', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
  })

  test('clears the search term when submitted empty', async () => {
    setLocation('http://localhost/creatives?search=roadmap')
    await mount()
    const input = document.querySelector('[data-search-popup-target="input"]')
    input.value = ''

    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })
    )

    expect(visit).toHaveBeenCalledWith('/creatives', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
  })

  test('ignores keys other than Enter in the search input', async () => {
    await mount()
    const input = document.querySelector('[data-search-popup-target="input"]')

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true }))

    expect(visit).not.toHaveBeenCalled()
  })

  test('closes the popup, which a frame-only navigation would leave open', async () => {
    await mount()

    click('[data-filter-state="comment"]')

    expect(popup.classList.contains('open')).toBe(false)
  })

  test('refreshes the stale GNB filter state after a frame-only navigation', async () => {
    setLocation('http://localhost/creatives?min_progress=0&max_progress=0.99')
    await mount()

    click('[data-filter="all"]')

    expect(document.querySelector('[data-filter-state="progress:all"]').classList).toContain(
      'active'
    )
    expect(
      document.querySelector('[data-filter-state="progress:incomplete"]').classList
    ).not.toContain('active')
    expect(document.querySelector('[data-filter-state="any-filter"]').classList).not.toContain(
      'active'
    )
  })

  test('sends filters to the creative index from a page that cannot use them', async () => {
    setLocation('http://localhost/settings?tab=profile')
    await mount({ onIndex: false, withFrame: false })

    click('[data-filter-state="comment"]')

    expect(visit).toHaveBeenCalledWith('/creatives?comment=true', { action: 'advance' })
  })

  test('leaves the filter state to the server when the whole page is replaced', async () => {
    await mount({ withFrame: false })

    click('[data-filter-state="comment"]')

    expect(document.querySelector('[data-filter-state="comment"]').classList).not.toContain(
      'active'
    )
  })

  test('does nothing when a progress button carries no filter', async () => {
    await mount()
    const button = document.querySelector('[data-filter="all"]')
    button.removeAttribute('data-filter')

    button.click()

    expect(visit).not.toHaveBeenCalled()
  })

  test('does nothing when a search mode button carries no mode', async () => {
    await mount()
    const button = document.querySelector('[data-mode="tree"]')
    button.removeAttribute('data-mode')

    button.click()

    expect(visit).not.toHaveBeenCalled()
  })
})
