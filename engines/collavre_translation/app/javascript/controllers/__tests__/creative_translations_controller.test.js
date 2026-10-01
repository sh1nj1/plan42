/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'

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
