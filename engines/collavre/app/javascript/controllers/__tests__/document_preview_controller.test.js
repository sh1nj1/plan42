import { Application } from '@hotwired/stimulus'
import DocumentPreviewController from '../document_preview_controller'

const settle = () => new Promise(resolve => setTimeout(resolve, 0))
test('lazy frames keep their placeholder until load and dynamically inserted previews connect', async () => {
  globalThis.KeyboardEvent = window.KeyboardEvent
  globalThis.MouseEvent = window.MouseEvent
  const application = Application.start()
  application.register('document-preview', DocumentPreviewController)
  document.body.innerHTML = `<span data-controller="document-preview" aria-busy="true"><span data-document-preview-target="loading"></span><iframe data-action="load->document-preview#loaded"></iframe></span>`
  await settle()
  const container = document.querySelector('span')
  expect(container.getAttribute('aria-busy')).toBe('true')
  container.querySelector('iframe').dispatchEvent(new window.Event('load'))
  expect(container.getAttribute('aria-busy')).toBe('false')
  expect(container.querySelector('[data-document-preview-target]').hidden).toBe(true)
  document.body.innerHTML = ''
  await settle()
  application.stop()
})

test('a frame that finished before Stimulus connects does not retain its loader', async () => {
  document.body.innerHTML = `<span data-controller="document-preview" aria-busy="true"><span data-document-preview-target="loading"></span><iframe></iframe></span>`
  const frame = document.querySelector('iframe')
  Object.defineProperty(frame.contentDocument, 'URL', {value: 'http://localhost/ppt_previews/signed'})
  const application = Application.start()
  application.register('document-preview', DocumentPreviewController)
  await settle()
  expect(document.querySelector('[aria-busy]').getAttribute('aria-busy')).toBe('false')
  document.body.innerHTML = ''
  await settle()
  application.stop()
})
