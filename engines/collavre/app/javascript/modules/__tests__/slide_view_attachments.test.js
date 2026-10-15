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
