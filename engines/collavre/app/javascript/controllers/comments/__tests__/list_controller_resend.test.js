/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import CommentsListController from '../list_controller'

describe('CommentsListController resend action integration', () => {
  let controller, originalFetch

  beforeEach(() => {
    document.body.innerHTML = `
      <div id="popup" data-resend-label="다시 보내기" data-resend-description="이후 AI 메시지를 삭제하고 다시 보냅니다">
        <div id="comments">
          <div id="comment_10" data-user-id="1" data-ai-user="false"><input class="comment-select-checkbox"></div>
          <div id="comment_11" data-user-id="2" data-ai-user="false"><input class="comment-select-checkbox"></div>
        </div>
      </div>`
    document.body.dataset.currentUserId = '1'
    controller = Object.create(CommentsListController.prototype)
    Object.defineProperty(controller, 'element', { value: document.getElementById('popup') })
    Object.defineProperty(controller, 'listTarget', { value: document.getElementById('comments') })
    controller.creativeId = '7'
    controller.selection = new Set(['10'])
    controller.clearSelection = jest.fn(() => controller.selection.clear())
    controller.loadInitialComments = jest.fn()
    originalFetch = global.fetch
    global.fetch = jest.fn().mockResolvedValue({ ok: true })
  })

  afterEach(() => {
    global.fetch = originalFetch
    document.body.innerHTML = ''
    delete document.body.dataset.currentUserId
  })

  test('renders a localized resend button and sends the selected own message on click', async () => {
    controller.updateSelectionActionBar()
    const button = controller.element.querySelector('.selection-action-resend')
    expect(button.disabled).toBe(false)
    expect(button.textContent).toBe('다시 보내기')
    expect(button.title).toBe('이후 AI 메시지를 삭제하고 다시 보냅니다')

    button.click()
    expect(button.disabled).toBe(true)
    expect(fetch).toHaveBeenCalledWith('/creatives/7/comments/10/resend', expect.objectContaining({ method: 'POST' }))
    await Promise.resolve()
    expect(controller.clearSelection).toHaveBeenCalledTimes(1)
    expect(controller.loadInitialComments).toHaveBeenCalledTimes(1)
    expect(controller.element.querySelector('.selection-action-bar')).toBeNull()
  })

  test.each([['11'], ['10', '11']])('disables resend for selection %j', (...ids) => {
    controller.selection = new Set(ids)
    controller.updateSelectionActionBar()
    const button = controller.element.querySelector('.selection-action-resend')
    expect(button.disabled).toBe(true)
    button.click()
    expect(fetch).not.toHaveBeenCalled()
  })

  test('rebuilds the resend action when the selection changes', () => {
    controller.updateSelectionActionBar()
    controller.selection.add('11')
    controller.updateSelectionActionBar()
    expect(controller.element.querySelectorAll('.selection-action-bar')).toHaveLength(1)
    expect(controller.element.querySelector('.selection-action-resend').disabled).toBe(true)
    controller.selection.delete('11')
    controller.updateSelectionActionBar()
    expect(controller.element.querySelector('.selection-action-resend').disabled).toBe(false)
  })
})
