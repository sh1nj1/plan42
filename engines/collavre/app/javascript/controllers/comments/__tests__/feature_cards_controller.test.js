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

  test('restoreAll issues a DELETE to the notices endpoint', () => {
    const fetchMock = jest.fn().mockResolvedValue({ ok: true })
    global.fetch = fetchMock
    controller._reloadComments = jest.fn()

    controller.restoreAll()

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

  test('openCommandMenu preserves an in-progress draft instead of overwriting it', () => {
    const form = document.createElement('form')
    form.id = 'new-comment-form'
    const textarea = document.createElement('textarea')
    textarea.value = 'unsent draft'
    form.appendChild(textarea)
    document.body.appendChild(form)

    const inputHandler = jest.fn()
    textarea.addEventListener('input', inputHandler)

    controller.openCommandMenu()

    expect(textarea.value).toBe('unsent draft')
    expect(document.activeElement).toBe(textarea)
    expect(inputHandler).not.toHaveBeenCalled()

    document.body.removeChild(form)
  })
})
