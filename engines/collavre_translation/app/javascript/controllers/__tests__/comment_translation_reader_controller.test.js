/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const fetchMock = jest.fn()
jest.unstable_mockModule('collavre/lib/api/csrf_fetch', () => ({ default: fetchMock }))
jest.unstable_mockModule('collavre/lib/utils/markdown', () => ({ renderCommentMarkdown: text => text, renderMermaidDiagrams: jest.fn() }))
const { registerControllers } = await import('../index')
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
const settle = async () => { await tick(); await tick() }
const markup = digest => `<div id="comment_1" class="comment-item">
  <div data-comment-target="content">Original ${digest}</div>
  <template data-comment-translation-template><div data-comment-translation-url-value="/translation/comments/1/translation"
    data-comment-translation-digest-value="${digest}">
    <button data-comment-translation-target="toggle" hidden></button>
    <div data-comment-translation-target="content" hidden></div>
  </div></template></div>`
let app, intersections
beforeEach(() => {
  fetchMock.mockReset()
  intersections = []
  global.IntersectionObserver = class {
    constructor(callback) { intersections.push(callback) }
    observe() {}
    disconnect() {}
  }
})
afterEach(async () => {
  document.body.replaceChildren()
  await settle()
  app.stop()
})

for (const enabled of [true, false]) {
  test(`shared live append and replacement honor an ${enabled ? 'ON' : 'OFF'} reader`, async () => {
    document.body.innerHTML = `${enabled ? '<span data-controller="comment-translation-reader" hidden></span>' : ''}<div id="comments-list"></div>`
    app = Application.start()
    registerControllers(app)
    await settle()
    for (const digest of ['created', 'edited']) {
      const stream = document.createElement('template')
      stream.innerHTML = markup(digest)
      const existing = document.querySelector('#comment_1')
      if (existing) existing.replaceWith(stream.content)
      else document.querySelector('#comments-list').append(stream.content)
      await settle()
      expect(document.querySelectorAll('[data-controller="comment-translation"]')).toHaveLength(enabled ? 1 : 0)
      if (enabled) {
        fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ status: 'missing', source_digest: digest }) })
          .mockResolvedValueOnce({ ok: true, json: async () => ({ status: 'processing', source_digest: digest }) })
          .mockResolvedValueOnce({ ok: true, json: async () => ({ status: 'completed', source_digest: digest, content: `Translated ${digest}` }) })
        intersections.at(-1)([{ isIntersecting: true }])
        await settle()
        const element = document.querySelector('[data-controller="comment-translation"]')
        const controller = app.getControllerForElementAndIdentifier(element, 'comment-translation')
        expect(fetchMock.mock.calls.at(-2)[1].method).toBe('GET')
        expect(fetchMock.mock.calls.at(-1)[1].method).toBe('POST')
        expect(controller.timer).toBeDefined()
        clearTimeout(controller.timer)
        await controller.load()
        expect(controller.contentTarget.textContent).toBe(`Translated ${digest}`)
      } else {
        expect(intersections).toHaveLength(0)
        expect(fetchMock).not.toHaveBeenCalled()
        expect(document.querySelector('[data-comment-target="content"]').hidden).toBe(false)
      }
    }
  })
}

test('hydrates existing comments on reconnect without duplicate controllers', async () => {
  document.body.innerHTML = `<span data-controller="comment-translation-reader" hidden></span>${markup('initial')}`
  app = Application.start()
  registerControllers(app)
  await settle()
  const reader = document.querySelector('[data-controller="comment-translation-reader"]')
  reader.remove()
  await settle()
  document.body.append(reader)
  await settle()
  expect(document.querySelectorAll('[data-controller="comment-translation"]')).toHaveLength(1)
  expect(intersections).toHaveLength(1)
  expect(fetchMock).not.toHaveBeenCalled()
})
