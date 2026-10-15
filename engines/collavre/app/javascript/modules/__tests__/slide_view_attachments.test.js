import { jest } from '@jest/globals'

jest.unstable_mockModule('../../services/cable', () => ({createSubscription: jest.fn()}))
jest.unstable_mockModule('../../lib/utils/markdown', () => ({highlightCodeBlocks: jest.fn()}))
jest.unstable_mockModule('../../lib/utils/table_download', () => ({addTableDownloadButtons: jest.fn()}))

await import('../slide_view')

test('decorates the server-rendered first slide without fetching it', () => {
  document.body.innerHTML = '<div id="slide-view" data-slide-ids="1,2"><div id="slide-content"><a download href="/file" data-filesize="2048">slides.pptx</a><a download href="/image"><img src="/image"></a></div></div>'
  globalThis.history = window.history
  const fetchMock = jest.spyOn(globalThis, 'fetch')
  document.dispatchEvent(new window.Event('DOMContentLoaded'))
  const link = document.querySelector('#slide-content a')
  expect(link.classList.contains('attachment-link')).toBe(true)
  expect(link.textContent).toBe('slides.pptx')
  expect(link.querySelector('.attachment-link-size').dataset.filesizeLabel).toBe('2 KB')
  expect(document.querySelector('#slide-content img')).not.toBeNull()
  expect(fetchMock).not.toHaveBeenCalled()
  fetchMock.mockRestore()
})


test('shared initializer leaves attachment viewer initialization to its module', () => {
  document.body.innerHTML = '<div id="slide-view"><div id="slide-content">PPT attachment</div></div>'
  const errors = []
  const listener = event => { errors.push(event.error); event.preventDefault() }
  window.addEventListener('error', listener)
  document.dispatchEvent(new window.Event('DOMContentLoaded'))
  window.removeEventListener('error', listener)
  expect(errors).toEqual([])
  expect(document.querySelector('#slide-content').textContent).toBe('PPT attachment')
})


test('decorates all document formats on a nonzero initial slide and after navigation', async () => {
  document.head.innerHTML = '<meta name="ppt-preview-url-template" content="/previews/PPT_BLOB_ID">'
  document.body.innerHTML = '<div id="slide-view" data-slide-ids="1,2" data-initial-index="1"><div id="slide-content"></div></div>'
  globalThis.history = window.history
  const animationFrame = globalThis.requestAnimationFrame
  globalThis.requestAnimationFrame = callback => callback()
  const formats = ['pptx', 'md', 'html', 'pdf']
  const description = formats.map(format => `<a download="file.${format}" href="/rails/active_storage/blobs/redirect/blob-${format}/file.${format}">file.${format}</a>`).join('')
  const fetchMock = jest.spyOn(globalThis, 'fetch').mockResolvedValue({json: async () => ({description})})
  const settle = () => new Promise(resolve => setTimeout(resolve, 0))
  const expectPreviews = () => {
    const frames = [...document.querySelectorAll('#slide-content iframe')]
    expect(frames.map(frame => frame.title)).toEqual(formats.map(format => `file.${format}`))
    expect(frames.map(frame => frame.getAttribute('src'))).toEqual(formats.map(format => `/previews/blob-${format}`))
    expect(document.querySelectorAll('#slide-content [data-controller="document-preview"][aria-busy="true"]')).toHaveLength(4)
    expect(document.querySelector('#slide-content a[download]')).toBeNull()
  }
  try {
    document.dispatchEvent(new window.Event('DOMContentLoaded'))
    await settle()
    expect(fetchMock).toHaveBeenCalledWith('/creatives/2.json')
    expectPreviews()
    for (const [key, id] of [['ArrowLeft', 1], ['ArrowRight', 2]]) {
      fetchMock.mockClear()
      window.dispatchEvent(new window.KeyboardEvent('keydown', {key}))
      await settle()
      expect(fetchMock).toHaveBeenCalledWith(`/creatives/${id}.json`)
      expectPreviews()
    }
  } finally {
    globalThis.requestAnimationFrame = animationFrame
    fetchMock.mockRestore()
    document.head.innerHTML = ''
    document.body.innerHTML = ''
  }
})
