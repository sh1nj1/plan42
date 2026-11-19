import { jest } from '@jest/globals'

jest.unstable_mockModule('../modules/slide_view', () => ({}))
jest.unstable_mockModule('../lib/ppt_formatting', () => ({}))
jest.unstable_mockModule('../modules/ppt_viewer', () => ({}))

const settle = () => new Promise(resolve => setTimeout(resolve, 0))

const preview = format => `<span data-controller="document-preview" aria-busy="true" data-format="${format}"><span data-document-preview-target="loading"></span><iframe data-action="load->document-preview#loaded"></iframe></span>`

test('slide entry point clears document loaders for initial and dynamically inserted previews', async () => {
  globalThis.KeyboardEvent = window.KeyboardEvent
  globalThis.MouseEvent = window.MouseEvent
  document.body.innerHTML = preview('pptx')
  await import('../slide_view')
  await settle()
  for (const format of ['pptx', 'md', 'html', 'pdf']) {
    if (format !== 'pptx') {
      document.body.innerHTML = preview(format)
      await settle()
    }
    const container = document.querySelector('[aria-busy]')
    expect(container.getAttribute('aria-busy')).toBe('true')
    container.querySelector('iframe').dispatchEvent(new window.Event('load'))
    expect(container.getAttribute('aria-busy')).toBe('false')
    expect(container.querySelector('[data-document-preview-target]').hidden).toBe(true)
  }
  document.body.innerHTML = ''
  await settle()
})
