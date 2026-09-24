/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import Controller from '../comment_version_controller'

const tick = () => new Promise(resolve => setTimeout(resolve, 0))

describe('comment version run metadata', () => {
  let app, controller
  const versions = [
    { id: 1, content: 'Old answer', run_options_html: '<span class="agent-run-options-label">sonnet · low</span>' },
    { id: 2, content: 'New answer', run_options_html: '<span class="agent-run-options-label">opus · max</span>' }
  ]
  beforeEach(async () => {
    document.body.innerHTML = `<div id="comment_1"><span class="agent-run-options-container">latest</span><div class="comment-content"></div>
      <div data-controller="comment-version" data-comment-version-content-target-value="comment_1"
        data-comment-version-total-value="2" data-comment-version-initial-index-value="2"
        data-comment-version-selected-version-id-value="2" data-comment-version-versions-url-value="/versions">
        <button data-comment-version-target="prevBtn"></button><button data-comment-version-target="nextBtn"></button>
        <span data-comment-version-target="indicator"></span><button data-comment-version-target="selectBtn"></button>
      </div></div>`
    app = Application.start()
    app.register('comment-version', Controller)
    await tick()
    controller = app.getControllerForElementAndIdentifier(document.querySelector('[data-controller]'), 'comment-version')
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ versions, selected_version_id: 2, total: 2 }) })
  })
  afterEach(() => { app.stop(); document.body.innerHTML = ''; jest.restoreAllMocks() })
  test('navigation displays content and audit options from the same version', async () => {
    await controller.prev()
    expect(document.querySelector('.comment-content').textContent).toContain('Old answer')
    expect(document.querySelector('.agent-run-options-label').textContent).toBe('sonnet · low')
    await controller.next()
    expect(document.querySelector('.comment-content').textContent).toContain('New answer')
    expect(document.querySelector('.agent-run-options-label').textContent).toBe('opus · max')
  })
  test('legacy versions remove the current run chip', async () => {
    await controller.fetchVersions()
    controller.versions = [{ id: 1, content: 'Legacy answer' }, versions[1]]
    await controller.prev()
    expect(document.querySelector('.agent-run-options-label')).toBeNull()
    expect(document.querySelector('.agent-run-options-container').textContent).toBe('')
  })
  test('selecting a browsed version keeps its content and chip together', async () => {
    await controller.prev()
    await controller.selectVersion()
    expect(fetch).toHaveBeenLastCalledWith('/versions/1/select', expect.objectContaining({ method: 'POST' }))
    expect(controller.selectedVersionId).toBe(1)
    expect(document.querySelector('.agent-run-options-label').textContent).toBe('sonnet · low')
  })
})
