/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import { setCreativeTitle } from 'collavre/lib/creative_title'

const fetchMock = jest.fn()
jest.unstable_mockModule('collavre/lib/api/csrf_fetch', () => ({ default: fetchMock }))
const { addTableDownloadButtons } = await import("collavre/lib/utils/table_download")
const { default: Controller } = await import('../creative_translations_controller')
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
const response = (status, content = null, digest = 'digest') => ({ ok: true,
  json: async () => ({ status, content, source_digest: digest, original_html: row.descriptionHtml }) })
const pairs = JSON.stringify([{ original: 'English title', translated: '번역 제목' },
  { original: 'Link label', translated: '<script>safe text</script>' },
  { original: 'Code', translated: 'must not change' },
  { original: '@Astra:', translated: 'must not change' }])
let app, controller, row, intersection
beforeEach(async () => {
  global.IntersectionObserver = class {
    constructor(callback) { intersection = callback }
    observe = jest.fn()
    unobserve = jest.fn()
    disconnect = jest.fn()
  }
  document.body.innerHTML = `<div id="creative-overflow-menu"></div><creative-tree-row creative-id="1"><div class="creative-content"><h1>English title</h1><a href="/path">Link label</a><pre><code>Code</code></pre><span class="mention">@Astra:</span></div></creative-tree-row>
    <div data-controller="creative-translations" data-creative-translations-base-value="/translation/creatives/__ID__/translation"
      data-creative-translations-original-value="Show original" data-creative-translations-translated-value="Show translation"></div>`
  row = document.querySelector('creative-tree-row')
  row.descriptionHtml = '<h1>English title</h1>'
  app = Application.start()
  app.register('creative-translations', Controller)
  await tick()
  controller = app.getControllerForElementAndIdentifier(document.querySelector('[data-controller]'), 'creative-translations')
  fetchMock.mockReset()
})
afterEach(async () => {
  controller.disconnect()
  app.stop()
  document.body.innerHTML = ''
  await tick()
})

test('loads visible creatives, preserves live structure and toggles original text', async () => {
  const link = row.querySelector('a')
  const handler = jest.fn(event => event.preventDefault())
  link.addEventListener('click', handler)
  expect(fetchMock).not.toHaveBeenCalled()
  intersection([{ target: row, isIntersecting: false }])
  expect(fetchMock).not.toHaveBeenCalled()
  fetchMock.mockResolvedValueOnce(response('missing')).mockResolvedValueOnce(response('completed', pairs))
  intersection([{ target: row, isIntersecting: true }])
  await tick()
  expect(fetchMock.mock.calls.map(call => call[1].method)).toEqual(['GET', 'POST'])
  expect(fetchMock.mock.calls[0][0]).toBe('/translation/creatives/1/translation')
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(row.querySelector('a')).toBe(link)
  expect(link.getAttribute('href')).toBe('/path')
  expect(link.textContent).toBe('<script>safe text</script>')
  expect(row.querySelector('script')).toBeNull()
  link.click()
  expect(handler).toHaveBeenCalledTimes(1)
  expect(row.querySelector('code').textContent).toBe('Code')
  expect(row.querySelector('.mention').textContent).toBe('@Astra:')
  expect(row.descriptionHtml).toBe('<h1>English title</h1>')
  const button = document.querySelector('.creative-translation-toggle')
  button.click()
  expect(row.querySelector('h1').textContent).toBe('English title')
  expect(button.getAttribute('aria-pressed')).toBe('false')
  button.click()
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  controller.show(row, controller.rows.get(row), JSON.parse(pairs))
  expect(row.querySelectorAll('.creative-translation-toggle')).toHaveLength(0)
  expect(document.querySelectorAll('.creative-translation-toggle')).toHaveLength(1)
})

test('polls pending cache and stops when source digest changes', async () => {
  fetchMock.mockResolvedValueOnce(response('pending')).mockResolvedValueOnce(response('processing'))
  await controller.load(row)
  const state = controller.rows.get(row)
  expect(state.delay).toBe(1000)
  clearTimeout(state.timer)
  fetchMock.mockResolvedValueOnce(response("processing"))
  await new Promise(resolve => { state.timer = setTimeout(async () => { await controller.load(row); resolve() }, 0) })
  clearTimeout(state.timer)
  fetchMock.mockResolvedValueOnce(response('completed', pairs, 'changed'))
  await controller.load(row)
  expect(row.querySelector('h1').textContent).toBe('English title')
})

test.each(['failed', 'skipped'])('%s keeps original without polling', async status => {
  fetchMock.mockResolvedValue(response(status))
  await controller.load(row)
  expect(controller.rows.get(row).timer).toBeUndefined()
  expect(row.querySelector('button')).toBeNull()
})

test('HTTP, network and malformed payload failures preserve original', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false }).mockRejectedValueOnce(new Error('network'))
    .mockResolvedValueOnce(response('completed', 'invalid JSON'))
  for (let i = 0; i < 3; i++) await controller.load(row)
  expect(row.querySelector('h1').textContent).toBe('English title')
})

test('source changes abort old requests and register fresh rows', async () => {
  let resolve
  fetchMock.mockImplementation(() => new Promise(done => { resolve = done }))
  const loading = controller.load(row)
  const old = controller.rows.get(row)
  row.descriptionHtml = 'Changed source'
  controller.scan()
  expect(old.abort.signal.aborted).toBe(true)
  resolve(response('completed', pairs))
  await loading
  expect(row.querySelector('h1').textContent).toBe('English title')
  expect(controller.rows.get(row)).not.toBe(old)
})

test('rerendered and removed rows clean up and restore originals', async () => {
  fetchMock.mockResolvedValue(response('completed', pairs))
  await controller.load(row)
  const old = controller.rows.get(row)
  row.querySelector('.creative-content').outerHTML = '<div class="creative-content"><h1>English title</h1></div>'
  controller.scan()
  expect(old.abort.signal.aborted).toBe(true)
  await controller.load(row)
  const state = controller.rows.get(row)
  row.remove()
  controller.scan()
  expect(state.abort.signal.aborted).toBe(true)
  expect(controller.rows.size).toBe(0)
  await controller.load(row)
})

test('empty, unmatched and missing content never create a toggle', () => {
  const state = controller.rows.get(row)
  controller.show(row, state, [])
  expect(row.querySelector('button')).toBeNull()
  row.querySelector('.creative-content').remove()
  controller.show(row, state, JSON.parse(pairs))
  expect(row.querySelector('button')).toBeNull()
})

test('title content translates and disconnect restores live original nodes', async () => {
  row.querySelector('.creative-content').className = 'creative-title-content'
  fetchMock.mockResolvedValue(response('completed', pairs))
  await controller.load(row)
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  controller.disconnect()
  expect(row.querySelector('h1').textContent).toBe('English title')
  expect(row.querySelector('button')).toBeNull()
})

test('scheduled poll executes the actual callback and stops at completion', async () => {
  jest.useFakeTimers()
  try {
    fetchMock.mockResolvedValueOnce(response('processing')).mockResolvedValueOnce(response('completed', pairs))
    await controller.load(row)
    await jest.advanceTimersByTimeAsync(1000)
    expect(row.querySelector('h1').textContent).toBe('번역 제목')
  } finally {
    jest.useRealTimers()
  }
})

test('server source mismatch leaves the stale view untranslated', async () => {
  const stale = response('completed', pairs)
  stale.json = async () => ({ status: 'completed', content: pairs, source_digest: 'new', original_html: 'New original' })
  fetchMock.mockResolvedValue(stale)
  await controller.load(row)
  expect(row.querySelector('button')).toBeNull()
})

test('CSV and Excel export the original table while translated display returns', async () => {
  row.querySelector('.creative-content').innerHTML = '<table><tr><th>English title</th></tr><tr><td>Link label</td></tr></table>'
  const content = row.querySelector('.creative-content')
  addTableDownloadButtons(content)
  fetchMock.mockResolvedValue(response('completed', pairs))
  await controller.load(row)
  const exported = []
  URL.createObjectURL = jest.fn(blob => { exported.push(blob); return 'blob:test' })
  URL.revokeObjectURL = jest.fn()
  const click = jest.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  const read = blob => new Promise(resolve => { const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.readAsText(blob) })
  try {
    for (const button of row.querySelectorAll('.table-download-btn')) {
      button.click()
      expect(content.querySelector('th').textContent).toBe('English title')
      await tick()
      expect(content.querySelector('th').textContent).toBe('번역 제목')
    }
    for (const blob of exported) {
      const text = await read(blob)
      expect(text).toContain('English title')
      expect(text).toContain('Link label')
      expect(text).not.toContain('번역 제목')
    }
    controller.toggle(controller.rows.get(row))
    row.querySelector('.table-download-btn').click()
    expect(content.querySelector('th').textContent).toBe('English title')
    controller.toggle(controller.rows.get(row))
    row.querySelector('.table-download-btn').click()
    controller.cleanup(row, controller.rows.get(row))
    await tick()
    expect(content.querySelector('th').textContent).toBe('English title')
  } finally { click.mockRestore() }
})

test('shared live append and replace use the existing reader controller', async () => {
  const originalRow = row
  const sharedRow = originalRow.cloneNode(true)
  sharedRow.setAttribute('creative-id', '2')
  sharedRow.descriptionHtml = originalRow.descriptionHtml
  document.body.append(sharedRow)
  await tick()
  expect(controller.rows.has(sharedRow)).toBe(true)
  row = sharedRow
  fetchMock.mockResolvedValue(response('completed', pairs))
  intersection([{ target: sharedRow, isIntersecting: true }])
  await tick()
  expect(sharedRow.querySelector('h1').textContent).toBe('번역 제목')
  expect(fetchMock.mock.calls[0][0]).toBe('/translation/creatives/2/translation')
  const replacement = originalRow.cloneNode(true)
  replacement.descriptionHtml = originalRow.descriptionHtml
  sharedRow.replaceWith(replacement)
  row = replacement
  await tick()
  expect(controller.rows.has(sharedRow)).toBe(false)
  expect(controller.rows.has(replacement)).toBe(true)
  intersection([{ target: replacement, isIntersecting: true }])
  await tick()
  expect(replacement.querySelector('h1').textContent).toBe('번역 제목')
  expect(document.querySelectorAll('[data-controller="creative-translations"]')).toHaveLength(1)
})

test('list menu applies original mode to later descendants and completed requests', async () => {
  document.querySelector('.creative-translation-toggle').click()
  fetchMock.mockResolvedValue(response('completed', pairs))
  await controller.load(row)
  expect(row.querySelector('h1').textContent).toBe('English title')
  const child = document.createElement('creative-tree-row')
  child.setAttribute('creative-id', '2')
  child.descriptionHtml = row.descriptionHtml
  child.innerHTML = '<div class="creative-content"><h1>English title</h1></div>'
  document.body.append(child)
  controller.scan()
  await controller.load(child)
  expect(child.querySelector('h1').textContent).toBe('English title')
  document.querySelector('.creative-translation-toggle').click()
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(child.querySelector('h1').textContent).toBe('번역 제목')
})

test('menu replacement preserves list mode without duplicate controls', () => {
  controller.menuButton.click()
  document.getElementById('creative-overflow-menu').remove()
  controller.scan()
  const menu = document.createElement('div')
  menu.id = 'creative-overflow-menu'
  document.body.append(menu)
  controller.scan()
  controller.scan()
  expect(menu.children).toHaveLength(1)
  expect(menu.textContent).toBe('Show translation')
})

function addTreeLink(label = 'English title') {
  const link = document.createElement('a')
  link.className = 'creative-workspace-tree-link'
  link.dataset.creativeId = '1'
  link.dataset.originalLabel = label
  link.dataset.creativeSnippet = 'Original snippet'
  link.href = '/creatives?id=1'
  link.textContent = label
  document.body.append(link)
  controller.scan()
  return link
}

test('workspace titles translate independently, preserve navigation and follow the list toggle', async () => {
  const link = addTreeLink()
  const clicked = jest.fn(event => event.preventDefault())
  link.addEventListener('click', clicked)
  fetchMock.mockResolvedValue(response('completed', pairs))
  intersection([{ target: link, isIntersecting: true }])
  await tick()
  expect(link.textContent).toBe('번역 제목')
  expect(link.dataset.originalLabel).toBe('English title')
  expect(link.dataset.creativeSnippet).toBe('Original snippet')
  expect(link.getAttribute('href')).toBe('/creatives?id=1')
  link.click()
  expect(clicked).toHaveBeenCalledTimes(1)
  controller.menuButton.click()
  expect(link.textContent).toBe('English title')
  const child = addTreeLink()
  await controller.load(child)
  expect(child.textContent).toBe('English title')
  controller.menuButton.click()
  expect(child.textContent).toBe('번역 제목')
  const state = controller.rows.get(link)
  link.remove()
  controller.scan()
  expect(state.abort.signal.aborted).toBe(true)
  controller.disconnect()
  expect(child.textContent).toBe('English title')
})

test('workspace polling and stale labels keep the original until a matching result completes', async () => {
  const link = addTreeLink()
  fetchMock.mockResolvedValueOnce(response('processing'))
  await controller.load(link)
  const state = controller.rows.get(link)
  expect(state.delay).toBe(1000)
  clearTimeout(state.timer)
  fetchMock.mockResolvedValue(response('completed', pairs))
  await controller.load(link)
  expect(link.textContent).toBe('번역 제목')
  const stale = addTreeLink('Edited title')
  await controller.load(stale)
  expect(stale.textContent).toBe('Edited title')
})

test('workspace labels combine inline text, decode entities and preserve protected content safely', async () => {
  const link = addTreeLink('English title Code @Astra:')
  fetchMock.mockResolvedValue({ ok: true, json: async () => ({ status: 'completed', content: pairs,
    original_html: '<h1>English&nbsp;title</h1> <code>Code</code> <span class="mention">@Astra:</span>', source_digest: 'digest' }) })
  await controller.load(link)
  expect(link.textContent).toBe('English title Code @Astra:')
  const rich = addTreeLink('English titleLink label Code @Astra:')
  fetchMock.mockResolvedValue({ ok: true, json: async () => ({ status: 'completed', content: pairs,
    original_html: '<h1>English title<a href="/">Link label</a></h1> <code>Code</code> <span class="mention">@Astra:</span>', source_digest: 'digest' }) })
  await controller.load(rich)
  expect(rich.textContent).toBe('번역 제목<script>safe text</script> Code @Astra:')
  expect(rich.querySelector('script')).toBeNull()
})

test('workspace labels request the unembedded source so YouTube link text still matches', async () => {
  const link = addTreeLink('English title Link label')
  fetchMock.mockResolvedValue({ ok: true, json: async () => ({ status: 'completed', content: pairs,
    original_html: '<h1>English title</h1> <a href="https://youtu.be/dQw4w9WgXcQ">Link label</a>', source_digest: 'digest' }) })
  await controller.load(link)
  expect(fetchMock).toHaveBeenLastCalledWith('/translation/creatives/1/translation?embed=0', expect.anything())
  expect(link.textContent).toBe('번역 제목 <script>safe text</script>')
  await controller.load(row)
  expect(fetchMock).toHaveBeenLastCalledWith('/translation/creatives/1/translation', expect.anything())
})

test('failed creative retries on reload but failure while polling waits for another reload', async () => {
  fetchMock.mockResolvedValueOnce(response('failed')).mockResolvedValueOnce(response('processing'))
  await controller.load(row)
  expect(fetchMock.mock.calls.map(call => call[1].method)).toEqual(['GET', 'POST'])
  clearTimeout(controller.rows.get(row).timer)
  fetchMock.mockResolvedValueOnce(response('failed'))
  await controller.load(row, false)
  expect(fetchMock.mock.calls.map(call => call[1].method)).toEqual(['GET', 'POST', 'GET'])
  expect(row.querySelector('h1').textContent).toBe('English title')
  controller.cleanup(row, controller.rows.get(row))
  controller.scan()
  fetchMock.mockResolvedValueOnce(response('failed')).mockResolvedValueOnce(response('completed', pairs))
  await controller.load(row)
  expect(fetchMock.mock.calls.map(call => call[1].method)).toEqual(['GET', 'POST', 'GET', 'GET', 'POST'])
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
})

function addNavigationLabel(text, id = '1', length = '24') {
  const title = document.createElement('h3')
  title.dataset.translationLabel = ''
  title.dataset.translationLength = length
  title.dataset.creativeId = id
  title.dataset.originalLabel = text
  title.textContent = text
  document.body.append(title)
  controller.scan()
  return title
}

test('breadcrumb and chat labels translate, truncate after translation and toggle together', async () => {
  const breadcrumb = addNavigationLabel('English title', '1', '20')
  const chat = addNavigationLabel('English title')
  const translated = 'A translated title that is much longer than the original'
  fetchMock.mockResolvedValue(response('completed', JSON.stringify([{ original: 'English title', translated }])))
  await controller.load(breadcrumb)
  await controller.load(chat)
  expect(breadcrumb.textContent).toBe(translated.slice(0, 17) + '...')
  expect(chat.textContent).toBe(translated.slice(0, 21) + '...')
  controller.menuButton.click()
  expect(breadcrumb.textContent).toBe('English title')
  expect(chat.textContent).toBe('English title')
})

test('truncated original labels match stored descriptions and reject stale titles', async () => {
  const title = addNavigationLabel('English...', '1', '10')
  fetchMock.mockResolvedValue(response('completed', pairs))
  await controller.load(title)
  expect(title.textContent).toBe('번역 제목')
  const stale = addNavigationLabel('Different...', '1', '10')
  await controller.load(stale)
  expect(stale.textContent).toBe('Different...')
})

test('chat navigation aborts stale requests and preserves the newly assigned title', async () => {
  const title = addNavigationLabel('English title')
  fetchMock.mockResolvedValue(response('completed', pairs))
  await controller.load(title)
  const previous = controller.rows.get(title)
  title.textContent = 'New title'
  title.dataset.originalLabel = 'New title'
  title.dataset.creativeId = '2'
  await tick()
  expect(previous.abort.signal.aborted).toBe(true)
  expect(title.textContent).toBe('New title')
  expect(controller.rows.get(title).id).toBe('2')
  fetchMock.mockResolvedValue({ ok: true, json: async () => ({ status: 'completed',
    original_html: '<p>New title</p>', content: JSON.stringify([{ original: 'New title', translated: '새 제목' }]) }) })
  await controller.load(title)
  expect(title.textContent).toBe('새 제목')
  expect(fetchMock).toHaveBeenLastCalledWith('/translation/creatives/2/translation?embed=0', expect.anything())
  title.textContent = 'Comments'
  delete title.dataset.creativeId
  delete title.dataset.originalLabel
  await tick()
  expect(controller.rows.has(title)).toBe(false)
  expect(title.textContent).toBe('Comments')
})

test('reopening the same chat preserves translated nodes and original toggling', async () => {
  const title = addNavigationLabel('English title')
  fetchMock.mockResolvedValue(response('completed', pairs))
  await controller.load(title)
  const state = controller.rows.get(title)
  const node = title.firstChild
  expect(title.textContent).toBe('번역 제목')
  title.hidden = true
  setCreativeTitle(title, 'English title', 1)
  title.hidden = false
  await tick()
  expect(controller.rows.get(title)).toBe(state)
  expect(title.firstChild).toBe(node)
  expect(title.textContent).toBe('번역 제목')
  controller.menuButton.click()
  expect(title.textContent).toBe('English title')
  setCreativeTitle(title, 'English title', '1')
  await tick()
  controller.menuButton.click()
  expect(title.textContent).toBe('번역 제목')
})

async function mountManual() {
  controller.disconnect()
  app.stop()
  document.querySelector('[data-controller]').dataset.creativeTranslationsAutoValue = 'false'
  app = Application.start()
  app.register('creative-translations', Controller)
  await tick()
  controller = app.getControllerForElementAndIdentifier(document.querySelector('[data-controller]'), 'creative-translations')
  fetchMock.mockReset()
}

test('automatic translation off offers the translation first and translates only on request', async () => {
  await mountManual()
  const button = document.querySelector('.creative-translation-toggle')
  expect(button.textContent).toBe('Show translation')
  expect(button.getAttribute('aria-pressed')).toBe('false')
  intersection([{ target: row, isIntersecting: true }, { target: document.createElement('div'), isIntersecting: true }])
  await tick()
  expect(fetchMock).not.toHaveBeenCalled()
  expect(row.querySelector('h1').textContent).toBe('English title')
  fetchMock.mockResolvedValueOnce(response('missing')).mockResolvedValueOnce(response('completed', pairs))
  button.click()
  await tick()
  expect(fetchMock.mock.calls.map(call => [call[0], call[1].method])).toEqual([
    ['/translation/creatives/1/translation?manual=1', 'GET'], ['/translation/creatives/1/translation?manual=1', 'POST']])
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(button.textContent).toBe('Show original')
  button.click()
  expect(row.querySelector('h1').textContent).toBe('English title')
  button.click()
  expect(fetchMock).toHaveBeenCalledTimes(2)
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  const link = addTreeLink()
  fetchMock.mockResolvedValue(response('completed', pairs))
  intersection([{ target: link, isIntersecting: true }])
  await tick()
  expect(fetchMock).toHaveBeenLastCalledWith('/translation/creatives/1/translation?embed=0&manual=1', expect.anything())
  expect(link.textContent).toBe('번역 제목')
})

test('showing translations re-requests missing results without duplicating in-flight loads', async () => {
  fetchMock.mockResolvedValue(response('skipped'))
  intersection([{ target: row, isIntersecting: true }])
  await tick()
  expect(fetchMock).toHaveBeenCalledTimes(1)
  const state = controller.rows.get(row)
  controller.menuButton.click()
  expect(fetchMock).toHaveBeenCalledTimes(1)
  fetchMock.mockReset()
  let resolve
  fetchMock.mockImplementation(() => new Promise(done => { resolve = done }))
  controller.menuButton.click()
  expect(state.loading).toBe(true)
  controller.menuButton.click()
  controller.menuButton.click()
  expect(fetchMock).toHaveBeenCalledTimes(1)
  expect(fetchMock.mock.calls[0][0]).toBe('/translation/creatives/1/translation?manual=1')
  resolve(response('processing'))
  await tick()
  expect(state.loading).toBe(false)
  expect(state.timer).toBeTruthy()
  controller.menuButton.click()
  controller.menuButton.click()
  expect(fetchMock).toHaveBeenCalledTimes(1)
  clearTimeout(state.timer)
})

test('showing translations during an automatic request retries manually when that request fails', async () => {
  let reject
  fetchMock.mockImplementationOnce(() => new Promise((_, fail) => { reject = fail }))
  intersection([{ target: row, isIntersecting: true }])
  const state = controller.rows.get(row)
  expect(fetchMock.mock.calls[0][0]).toBe('/translation/creatives/1/translation')
  controller.menuButton.click()
  controller.menuButton.click()
  expect(state.retry).toBe(true)
  fetchMock.mockResolvedValueOnce(response('failed')).mockResolvedValueOnce(response('completed', pairs))
  reject(new Error('offline'))
  await tick()
  expect(fetchMock.mock.calls.slice(1).map(call => [call[0], call[1].method])).toEqual([
    ['/translation/creatives/1/translation?manual=1', 'GET'], ['/translation/creatives/1/translation?manual=1', 'POST']])
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(state.retry).toBe(false)
})

test('showing translations while polling retries a failed result on the next poll', async () => {
  fetchMock.mockResolvedValueOnce(response('pending')).mockResolvedValueOnce(response('processing'))
  intersection([{ target: row, isIntersecting: true }])
  await tick()
  const state = controller.rows.get(row)
  expect(state.timer).toBeTruthy()
  controller.menuButton.click()
  controller.menuButton.click()
  fetchMock.mockReset()
  fetchMock.mockResolvedValueOnce(response('failed')).mockResolvedValueOnce(response('completed', pairs))
  clearTimeout(state.timer)
  await controller.load(row, false)
  expect(fetchMock.mock.calls.map(call => call[1].method)).toEqual(['GET', 'POST'])
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
})

test('a retry requested mid-flight is dropped once the reader returns to the original', async () => {
  let resolve
  fetchMock.mockImplementationOnce(() => new Promise(done => { resolve = done }))
  intersection([{ target: row, isIntersecting: true }])
  controller.menuButton.click()
  controller.menuButton.click()
  controller.menuButton.click()
  resolve({ ok: false })
  await tick()
  expect(fetchMock).toHaveBeenCalledTimes(1)
  expect(row.querySelector('h1').textContent).toBe('English title')
})

test('policy-rejected automatic loads offer a manual translation on the first click', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false, status: 403 })
  intersection([{ target: row, isIntersecting: true }])
  await tick()
  expect(controller.menuButton.textContent).toBe('Show translation')
  expect(controller.menuButton.getAttribute('aria-pressed')).toBe('false')
  fetchMock.mockResolvedValueOnce(response('missing')).mockResolvedValueOnce(response('completed', pairs))
  controller.menuButton.click()
  await tick()
  expect(fetchMock.mock.calls.slice(1).map(call => [call[0], call[1].method])).toEqual([
    ['/translation/creatives/1/translation?manual=1', 'GET'], ['/translation/creatives/1/translation?manual=1', 'POST']])
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(controller.menuButton.textContent).toBe('Show original')
})

test('manual policy denial preserves translations and allows restoring originals', async () => {
  fetchMock.mockResolvedValueOnce(response('completed', pairs))
  intersection([{ target: row, isIntersecting: true }])
  await tick()
  const link = addTreeLink()
  fetchMock.mockResolvedValueOnce({ ok: false, status: 403 })
  intersection([{ target: link, isIntersecting: true }])
  await tick()
  expect(controller.menuButton.textContent).toBe('Show translation')
  fetchMock.mockResolvedValueOnce({ ok: false, status: 403 })
  controller.menuButton.click()
  await tick()
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(controller.menuButton.textContent).toBe('Show original')
  controller.menuButton.click()
  expect(row.querySelector('h1').textContent).toBe('English title')
  controller.menuButton.click()
  await tick()
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(fetchMock).toHaveBeenLastCalledWith('/translation/creatives/1/translation?embed=0&manual=1', expect.anything())
  link.remove()
  controller.scan()
  expect(controller.menuButton.textContent).toBe('Show original')
})


test('loads can finish before the overflow menu mounts', async () => {
  document.getElementById('creative-overflow-menu').remove()
  controller.menuButton = undefined
  fetchMock.mockResolvedValueOnce(response('completed', pairs))
  await controller.load(row)
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  document.body.insertAdjacentHTML('beforeend', '<div id="creative-overflow-menu"></div>')
  controller.scan()
  expect(controller.menuButton.textContent).toBe('Show original')
})

test.each(['network', 'GET 500', 'POST 503'])('manual %s failure offers a one-click retry', async failure => {
  controller.showTranslated = false
  controller.autoValue = false
  controller.updateMenu()
  intersection([{ target: row, isIntersecting: true }])
  if (failure === 'network') fetchMock.mockRejectedValueOnce(new Error('offline'))
  else {
    if (failure === 'POST 503') fetchMock.mockResolvedValueOnce(response('missing'))
    fetchMock.mockResolvedValueOnce({ ok: false, status: failure === 'GET 500' ? 500 : 503 })
  }
  controller.menuButton.click()
  await tick()
  expect(controller.menuButton.textContent).toBe('Show translation')
  expect(row.querySelector('h1').textContent).toBe('English title')
  fetchMock.mockResolvedValueOnce(response('completed', pairs))
  controller.menuButton.click()
  await tick()
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(controller.menuButton.textContent).toBe('Show original')
})


test.each(['cooldown', 'poll'])('manual failed %s result preserves one-click retry without polling', async failure => {
  controller.showTranslated = false
  controller.autoValue = false
  controller.updateMenu()
  intersection([{ target: row, isIntersecting: true }])
  fetchMock.mockResolvedValueOnce(response('failed'))
    .mockResolvedValueOnce(response(failure === 'cooldown' ? 'failed' : 'processing'))
  controller.menuButton.click()
  await tick()
  const state = controller.rows.get(row)
  if (failure === 'poll') {
    clearTimeout(state.timer)
    fetchMock.mockResolvedValueOnce(response('failed'))
    await controller.load(row, false)
  }
  expect(state.timer).toBeUndefined()
  expect(controller.menuButton.textContent).toBe('Show translation')
  expect(row.querySelector('h1').textContent).toBe('English title')
  const calls = fetchMock.mock.calls.length
  await tick()
  expect(fetchMock).toHaveBeenCalledTimes(calls)
  fetchMock.mockResolvedValueOnce(response('failed')).mockResolvedValueOnce(response('completed', pairs))
  controller.menuButton.click()
  await tick()
  expect(fetchMock.mock.calls.slice(calls).map(([url, options]) => [url, options.method])).toEqual([
    ['/translation/creatives/1/translation?manual=1', 'GET'],
    ['/translation/creatives/1/translation?manual=1', 'POST']
  ])
  expect(row.querySelector('h1').textContent).toBe('번역 제목')
  expect(controller.menuButton.textContent).toBe('Show original')
  controller.menuButton.click()
  expect(row.querySelector('h1').textContent).toBe('English title')
})
