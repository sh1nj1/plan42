/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const { default: ProgressFilterController } = await import('../progress_filter_controller')

const WORKSPACE_FRAME_ID = 'creative-workspace-content'

describe('ProgressFilterController', () => {
  let application
  let visit

  // jsdom's window.location is unforgeable, so drive it through history.
  function setLocation(href) {
    window.history.replaceState({}, '', href)
  }

  async function mount({ onIndex = true, withFrame = true, indexPath = '/creatives' } = {}) {
    document.body.innerHTML = `
      ${withFrame ? `<turbo-frame id="${WORKSPACE_FRAME_ID}"></turbo-frame>` : ''}
      <div class="progress-filter-group"
           data-controller="progress-filter"
           data-progress-filter-index-path-value="${indexPath}"
           data-progress-filter-on-index-value="${onIndex}">
        <button class="progress-filter-btn"
                data-action="click->progress-filter#apply"
                data-progress-filter-target="button"
                data-filter-state="comment"
                data-progress-filter-filter-param="comment">Chat</button>
      </div>
    `

    application = Application.start()
    application.register('progress-filter', ProgressFilterController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    return document.querySelector('.progress-filter-btn')
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

  test('replaces only the workspace frame instead of reloading the page', async () => {
    const button = await mount()

    button.click()

    expect(visit).toHaveBeenCalledWith('/creatives?comment=true', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
    expect(window.location.href).toBe('http://localhost/creatives')
  })

  test('preserves the other list filters already in the URL', async () => {
    setLocation('http://localhost/creatives?id=7&search=hi')
    const button = await mount()

    button.click()

    const [target] = visit.mock.calls[0]
    expect(target).toContain('id=7')
    expect(target).toContain('search=hi')
    expect(target).toContain('comment=true')
  })

  test('toggles the comment filter back off', async () => {
    setLocation('http://localhost/creatives?comment=true')
    const button = await mount()

    button.click()

    expect(visit).toHaveBeenCalledWith('/creatives', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
  })

  test('updates the button state, which the untouched GNB would otherwise keep stale', async () => {
    const button = await mount()

    button.click()
    expect(button.classList.contains('active')).toBe(true)
  })

  test('navigates to the creative index from a page that cannot use the filter', async () => {
    setLocation('http://localhost/settings?tab=profile')
    const button = await mount({ onIndex: false, withFrame: false })

    button.click()

    expect(visit).toHaveBeenCalledWith('/creatives?comment=true', { action: 'advance' })
  })

  test('leaves the button state to the server when the whole page is replaced', async () => {
    const button = await mount({ withFrame: false })

    button.click()

    expect(visit).toHaveBeenCalledWith('/creatives?comment=true', { action: 'advance' })
    expect(button.classList.contains('active')).toBe(false)
  })

  test('prevents the default click action', async () => {
    const button = await mount()

    const event = new MouseEvent('click', { bubbles: true, cancelable: true })
    button.dispatchEvent(event)

    expect(event.defaultPrevented).toBe(true)
  })

  test('does nothing when the button carries no filter', async () => {
    const button = await mount()
    button.removeAttribute('data-progress-filter-filter-param')

    button.click()

    expect(visit).not.toHaveBeenCalled()
  })
})
