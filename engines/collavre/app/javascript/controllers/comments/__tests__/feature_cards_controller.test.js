/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application, Controller } from '@hotwired/stimulus'
import FeatureCardsController from '../feature_cards_controller'

describe('FeatureCardsController', () => {
  let application
  let container
  let controller

  const FIXTURE = `
    <div id="no-comments" data-controller="comments--feature-cards">
      <template data-comments--feature-cards-target="minimalTemplate">
        <div class="chat-empty-minimal">
          <p>Start a conversation</p>
          <button type="button" class="chat-empty-restore-btn" data-action="click->comments--feature-cards#restoreAll">?</button>
        </div>
      </template>
      <div class="feature-card-grid" data-comments--feature-cards-target="grid">
        <div class="feature-card" data-key="slash_command" data-comments--feature-cards-target="card">
          <button type="button" class="feature-card-dismiss" data-action="click->comments--feature-cards#dismiss" data-key="slash_command">&times;</button>
        </div>
        <div class="feature-card" data-key="add_user" data-comments--feature-cards-target="card">
          <button type="button" class="feature-card-dismiss" data-action="click->comments--feature-cards#dismiss" data-key="add_user">&times;</button>
        </div>
      </div>
    </div>`

  beforeEach(async () => {
    const meta = document.createElement('meta')
    meta.name = 'csrf-token'
    meta.content = 'test-token'
    document.head.appendChild(meta)

    container = document.createElement('div')
    container.innerHTML = FIXTURE
    document.body.appendChild(container)

    application = Application.start()
    application.register('comments--feature-cards', FeatureCardsController)
    await new Promise((r) => setTimeout(r, 0))
    controller = application.getControllerForElementAndIdentifier(
      container.querySelector('#no-comments'),
      'comments--feature-cards',
    )
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    document.head.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('dismiss removes the clicked card and POSTs to the dismiss endpoint', () => {
    const fetchMock = jest.fn().mockResolvedValue({ ok: true })
    global.fetch = fetchMock

    container.querySelector('[data-key="slash_command"].feature-card-dismiss').click()

    expect(container.querySelectorAll('.feature-card')).toHaveLength(1)
    expect(fetchMock).toHaveBeenCalledWith(
      '/notices/slash_command/dismiss',
      expect.objectContaining({ method: 'POST' }),
    )
  })

  test('dismissing the last card swaps in the minimal empty state', () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true })

    container.querySelector('[data-key="slash_command"].feature-card-dismiss').click()
    container.querySelector('[data-key="add_user"].feature-card-dismiss').click()

    expect(container.querySelectorAll('.feature-card')).toHaveLength(0)
    expect(container.querySelector('.chat-empty-minimal')).not.toBeNull()
    expect(container.querySelector('.chat-empty-restore-btn')).not.toBeNull()
  })

  test('restoreAll issues a DELETE to the notices endpoint', async () => {
    const fetchMock = jest.fn().mockResolvedValue({ ok: true, headers: new Headers() })
    global.fetch = fetchMock
    controller._reloadComments = jest.fn()

    await controller.restoreAll()

    expect(fetchMock).toHaveBeenCalledWith('/notices', expect.objectContaining({ method: 'DELETE' }))
  })

  test('restoreAll reloads comments via this.application, without a window.Stimulus global', async () => {
    // Embedding hosts register controllers on a local application and never
    // assign window.Stimulus (see engines/collavre/docs/installation.md).
    delete window.Stimulus

    const popup = document.createElement('div')
    popup.id = 'comments-popup'
    popup.setAttribute('data-controller', 'comments--list')
    container.querySelector('#no-comments').replaceWith(popup)
    popup.innerHTML = FIXTURE

    const loadInitialComments = jest.fn()
    application.register(
      'comments--list',
      class extends Controller {
        loadInitialComments = loadInitialComments
      },
    )
    await new Promise((r) => setTimeout(r, 0))

    const cardsController = application.getControllerForElementAndIdentifier(
      popup.querySelector('#no-comments'),
      'comments--feature-cards',
    )
    // csrfFetch reads X-CSRF-Token off the response, so the mock needs headers.
    global.fetch = jest.fn().mockResolvedValue({ ok: true, headers: new Headers() })

    await cardsController.restoreAll()

    expect(loadInitialComments).toHaveBeenCalledTimes(1)
  })

  test('restoreAll waits for in-flight dismissals before issuing the DELETE', async () => {
    // Dismissing the last card reveals the restore button immediately, so the
    // user can click it while the dismiss POSTs are still in flight. If the
    // DELETE lands first, the late dismissal wins and the card stays hidden.
    const dismissResolvers = []
    const fetchMock = jest.fn((url) => {
      if (url.includes('/dismiss')) {
        return new Promise((resolve) => {
          dismissResolvers.push(() => resolve({ ok: true, headers: new Headers() }))
        })
      }
      return Promise.resolve({ ok: true, headers: new Headers() })
    })
    global.fetch = fetchMock
    controller._reloadComments = jest.fn()

    container.querySelector('[data-key="slash_command"].feature-card-dismiss').click()
    container.querySelector('[data-key="add_user"].feature-card-dismiss').click()
    expect(dismissResolvers).toHaveLength(2)

    const restored = controller.restoreAll()
    await new Promise((r) => setTimeout(r, 0))

    const deleteCalls = () =>
      fetchMock.mock.calls.filter(([url, opts]) => url === '/notices' && opts?.method === 'DELETE')
    expect(deleteCalls()).toHaveLength(0)

    dismissResolvers.forEach((resolve) => resolve())
    await restored

    expect(deleteCalls()).toHaveLength(1)
    expect(controller._reloadComments).toHaveBeenCalledTimes(1)
  })

  test('openCommandMenu focuses the textarea, inserts "/" and dispatches input', () => {
    const form = document.createElement('form')
    form.id = 'new-comment-form'
    const textarea = document.createElement('textarea')
    form.appendChild(textarea)
    document.body.appendChild(form)

    const inputHandler = jest.fn()
    textarea.addEventListener('input', inputHandler)

    controller.openCommandMenu()

    expect(textarea.value).toBe('/')
    expect(document.activeElement).toBe(textarea)
    expect(inputHandler).toHaveBeenCalledTimes(1)

    document.body.removeChild(form)
  })

  // modules/command_menu.js only opens the menu when the text before the caret
  // matches this — i.e. a "/" token at the very start of the message.
  const MENU_TRIGGER = /^\/([^\s/]*)$/
  const triggerQuery = (textarea) =>
    textarea.value.slice(0, textarea.selectionStart).match(MENU_TRIGGER)?.[1]

  test('openCommandMenu keeps an in-progress draft and still opens the menu', () => {
    const form = document.createElement('form')
    form.id = 'new-comment-form'
    const textarea = document.createElement('textarea')
    textarea.value = 'unsent draft'
    form.appendChild(textarea)
    document.body.appendChild(form)

    const inputHandler = jest.fn()
    textarea.addEventListener('input', inputHandler)

    controller.openCommandMenu()

    // The draft survives, prefixed by the "/" the menu needs to trigger.
    expect(textarea.value).toBe('/unsent draft')
    expect(document.activeElement).toBe(textarea)
    expect(inputHandler).toHaveBeenCalledTimes(1)
    // Caret sits right after the injected "/", so the unfiltered list shows
    // rather than the menu trying to match "unsent draft" as a command name.
    expect(triggerQuery(textarea)).toBe('')

    document.body.removeChild(form)
  })

  test('openCommandMenu keeps a partial command as the menu filter', () => {
    const form = document.createElement('form')
    form.id = 'new-comment-form'
    const textarea = document.createElement('textarea')
    textarea.value = '/top'
    form.appendChild(textarea)
    document.body.appendChild(form)

    controller.openCommandMenu()

    expect(textarea.value).toBe('/top')
    expect(triggerQuery(textarea)).toBe('top')

    document.body.removeChild(form)
  })

})
