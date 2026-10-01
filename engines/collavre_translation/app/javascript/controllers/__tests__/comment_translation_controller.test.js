/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

const fetchMock = jest.fn()
const mermaidMock = jest.fn()
const renderMock = jest.fn(text => `<p>${text}</p>`)
jest.unstable_mockModule('collavre/lib/api/csrf_fetch', () => ({ default: fetchMock }))
jest.unstable_mockModule('collavre/lib/utils/markdown', () => ({ renderCommentMarkdown: renderMock, renderMermaidDiagrams: mermaidMock }))
const { default: Controller } = await import('../comment_translation_controller')
const { registerControllers } = await import('../index')
await import('../../collavre_translation')
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
const result = (status, content = null, digest = 'source') => ({ ok: true,
  json: async () => ({ status, content, source_digest: digest }) })

let app, controller, intersection
beforeEach(async () => {
  global.IntersectionObserver = class {
    constructor(callback) { intersection = callback }
    observe = jest.fn()
    disconnect = jest.fn()
  }
  document.body.innerHTML = `<div class="comment-item"><div data-comment-target="content">Original</div>
    <div data-controller="comment-translation" data-comment-translation-url-value="/translation/comments/1/translation"
      data-comment-translation-digest-value="source" data-comment-translation-loading-value="Translating"
      data-comment-translation-translated-value="Translated" data-comment-translation-original-value="Show original"
      data-comment-translation-show-translation-value="Show translation">
      <button data-comment-translation-target="toggle" data-action="comment-translation#toggle" hidden></button>
      <div data-comment-translation-target="content" hidden></div>
    </div></div>`
  app = Application.start()
  registerControllers(app)
  await tick()
  controller = app.getControllerForElementAndIdentifier(document.querySelector('[data-controller]'), 'comment-translation')
  fetchMock.mockReset()
  mermaidMock.mockReset()
})
afterEach(async () => {
  controller.disconnect()
  app.stop()
  document.body.innerHTML = ''
  jest.useRealTimers()
  jest.restoreAllMocks()
  await tick()
})

test('waits for viewport then requests missing translation and polls to completion', async () => {
  expect(fetchMock).not.toHaveBeenCalled()
  intersection([{ isIntersecting: false }])
  expect(fetchMock).not.toHaveBeenCalled()
  fetchMock.mockResolvedValueOnce(result('missing')).mockResolvedValueOnce(result('processing'))
  intersection([{ isIntersecting: true }])
  await tick()
  expect(fetchMock.mock.calls.map(call => call[1].method)).toEqual(['GET', 'POST'])
  expect(controller.toggleTarget.textContent).toBe('Translating')
  expect(controller.original.hidden).toBe(false)
  clearTimeout(controller.timer)
  fetchMock.mockResolvedValueOnce(result('completed', '번역 결과'))
  await controller.load()
  expect(controller.original.hidden).toBe(true)
  expect(controller.contentTarget.innerHTML).toBe('<p>번역 결과</p>')
  controller.toggle()
  expect(controller.original.hidden).toBe(false)
  expect(controller.toggleTarget.textContent).toBe('Show translation')
  controller.toggle()
  expect(controller.contentTarget.hidden).toBe(false)
})

test('cached translation does not issue POST', async () => {
  fetchMock.mockResolvedValue(result('completed', 'Cached'))
  await controller.load()
  expect(fetchMock).toHaveBeenCalledTimes(1)
  expect(fetchMock.mock.calls[0][1].method).toBe('GET')
  expect(controller.toggleTarget.getAttribute('aria-pressed')).toBe('true')
})

test.each(['failed', 'skipped'])('%s preserves original', async status => {
  fetchMock.mockResolvedValue(result(status))
  await controller.load()
  expect(controller.original.hidden).toBe(false)
  expect(controller.toggleTarget.hidden).toBe(true)
})

test('HTTP failure and thrown network errors preserve original', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false })
  await controller.load()
  expect(controller.original.hidden).toBe(false)
  fetchMock.mockRejectedValueOnce(new Error('offline'))
  await controller.load()
  expect(controller.toggleTarget.hidden).toBe(true)
})

test('stale digest, empty content and aborted requests do not display a translation', async () => {
  fetchMock.mockResolvedValueOnce(result('completed', 'Stale', 'different'))
  await controller.load()
  expect(controller.original.hidden).toBe(false)
  fetchMock.mockResolvedValueOnce(result('completed', ''))
  await controller.load()
  expect(controller.original.hidden).toBe(false)
  controller.abort.abort()
  controller.handleResponse({ status: 'completed', content: 'Stale', source_digest: 'source' })
  expect(controller.original.hidden).toBe(false)
})

test('editing or browsing versions invalidates translation even while request is pending', async () => {
  fetchMock.mockResolvedValueOnce(result('processing'))
  await controller.load()
  controller.original.textContent = 'Changed version'
  await tick()
  expect(controller.abort.signal.aborted).toBe(true)
  expect(controller.toggleTarget.hidden).toBe(true)
  expect(controller.original.hidden).toBe(false)
})

test('queued translations keep polling beyond two minutes with capped backoff until completion', async () => {
  jest.useFakeTimers()
  const initialTime = Date.now()
  fetchMock.mockResolvedValueOnce(result('processing'))
  await controller.load()
  expect(controller.pollDelay).toBe(2000)
  fetchMock.mockResolvedValueOnce(result('processing'))
  await jest.advanceTimersByTimeAsync(2000)
  expect(controller.pollDelay).toBe(4000)
  fetchMock.mockResolvedValueOnce(result('translating'))
  await jest.advanceTimersByTimeAsync(4000)
  expect(controller.pollDelay).toBe(8000)
  fetchMock.mockResolvedValueOnce(result('processing'))
  await jest.advanceTimersByTimeAsync(8000)
  expect(controller.pollDelay).toBe(10000)
  jest.setSystemTime(initialTime + 600000)
  fetchMock.mockResolvedValueOnce(result('translating'))
  await jest.advanceTimersByTimeAsync(10000)
  expect(controller.toggleTarget.hidden).toBe(false)
  expect(controller.toggleTarget.disabled).toBe(true)
  expect(controller.pollDelay).toBe(10000)
  fetchMock.mockResolvedValueOnce(result('completed', 'Delayed translation'))
  await jest.advanceTimersByTimeAsync(10000)
  expect(controller.contentTarget.textContent).toBe('Delayed translation')
  expect(controller.original.hidden).toBe(true)
  expect(controller.toggleTarget.disabled).toBe(false)
  const requestCount = fetchMock.mock.calls.length
  await jest.advanceTimersByTimeAsync(20000)
  expect(fetchMock).toHaveBeenCalledTimes(requestCount)
})

test('disconnect restores original and aborts pending work', async () => {
  fetchMock.mockResolvedValueOnce(result('completed', 'Cached'))
  await controller.load()
  controller.disconnect()
  expect(controller.original.hidden).toBe(false)
  expect(controller.abort.signal.aborted).toBe(true)
})

test('missing original content does not observe or request', () => {
  controller.original.remove()
  controller.connect()
  expect(controller.original).toBeNull()
  expect(fetchMock).not.toHaveBeenCalled()
})

test('pending states poll again and stop cleanly on failure', async () => {
  jest.useFakeTimers()
  fetchMock.mockResolvedValueOnce(result('pending')).mockResolvedValueOnce(result('processing')).mockResolvedValueOnce(result('failed'))
  await controller.load()
  expect(controller.toggleTarget.disabled).toBe(true)
  await jest.advanceTimersByTimeAsync(2000)
  expect(fetchMock.mock.calls.map(call => call[1].method)).toEqual(['GET', 'POST', 'GET'])
  expect(controller.toggleTarget.hidden).toBe(true)
})

test('disconnect is safe before content is connected', () => {
  controller.original = null
  controller.restoreOriginal()
  controller.abort = null
  controller.observer = null
  controller.mutations = null
  expect(() => controller.disconnect()).not.toThrow()
})

test('renders Mermaid after translated content becomes visible and preserves it across toggles', async () => {
  const content = 'Diagram\n```mermaid\ngraph TD; A-->B\n```'
  renderMock.mockReturnValueOnce('<div class="mermaid-chart">graph TD; A--&gt;B</div>')
  mermaidMock.mockImplementationOnce(container => {
    expect(container.hidden).toBe(false)
    expect(controller.original.hidden).toBe(true)
    expect(container.querySelector('.mermaid-chart').textContent).toBe('graph TD; A-->B')
    container.querySelector('.mermaid-chart').innerHTML = '<svg></svg>'
  })
  fetchMock.mockResolvedValueOnce(result('completed', content))
  await controller.load()
  expect(renderMock).toHaveBeenLastCalledWith(content)
  expect(mermaidMock).toHaveBeenCalledTimes(1)
  expect(mermaidMock).toHaveBeenCalledWith(controller.contentTarget)
  controller.toggle()
  controller.toggle()
  expect(controller.contentTarget.querySelector('svg')).not.toBeNull()
  expect(mermaidMock).toHaveBeenCalledTimes(1)
})


test('adds working table download controls to translated content and preserves them across toggles', async () => {
  renderMock.mockReturnValueOnce('<table><tr><th>Name</th></tr><tr><td>Translated</td></tr></table>')
  fetchMock.mockResolvedValueOnce(result('completed', '| Name |\n| --- |\n| Translated |'))
  URL.createObjectURL = jest.fn(() => 'blob:table')
  URL.revokeObjectURL = jest.fn()
  const click = jest.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  await controller.load()
  const buttons = controller.contentTarget.querySelectorAll('.table-download-btn')
  expect([...buttons].map(button => button.textContent)).toEqual(['⤓ CSV', '⤓ Excel'])
  expect(controller.contentTarget.querySelector('.table-download-wrapper table').textContent).toBe('NameTranslated')
  buttons.forEach(button => button.click())
  expect(click.mock.instances.map(anchor => anchor.download)).toEqual(['table_Name.csv', 'table_Name.xls'])
  expect(URL.createObjectURL).toHaveBeenCalledTimes(2)
  expect(URL.revokeObjectURL).toHaveBeenCalledTimes(2)
  controller.toggle()
  expect(controller.contentTarget.hidden).toBe(true)
  controller.toggle()
  expect(controller.contentTarget.hidden).toBe(false)
  expect(controller.contentTarget.querySelectorAll('.table-download-toolbar')).toHaveLength(1)
  expect(controller.contentTarget.querySelectorAll('.table-download-btn')[0]).toBe(buttons[0])
})

test('Mermaid decoration during an in-flight request does not invalidate translation', async () => {
  controller.original.innerHTML = '<div class="mermaid-chart"><span>graph TD; A--&gt;B</span></div>'
  let resolveRequest
  fetchMock.mockImplementationOnce(() => new Promise(resolve => { resolveRequest = resolve }))
  const loading = controller.load()
  const chart = controller.original.querySelector('.mermaid-chart')
  chart.firstChild.firstChild.textContent = 'decorating'
  await tick()
  expect(controller.abort.signal.aborted).toBe(false)
  chart.innerHTML = '<svg><g></g></svg>'
  await tick()
  expect(controller.abort.signal.aborted).toBe(false)
  resolveRequest(result('completed', 'Translated diagram'))
  await loading
  expect(controller.original.hidden).toBe(true)
  expect(controller.toggleTarget.hidden).toBe(false)
  controller.original.append('Edited source')
  await tick()
  expect(controller.abort.signal.aborted).toBe(true)
  expect(controller.original.hidden).toBe(false)
})
