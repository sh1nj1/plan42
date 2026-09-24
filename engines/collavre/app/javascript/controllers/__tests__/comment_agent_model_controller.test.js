/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import Controller from '../comment_agent_model_controller'
import { createUserMenu } from '../../comments/user_menu'

const tick = () => new Promise(resolve => setTimeout(resolve, 0))
const editor = '<form data-error="Save failed"><input name="user[llm_model]" value="opus"><select name="user[reasoning_effort]"><option value="low" selected>low</option></select><input type="submit"><p role="status"></p></form>'

describe('avatar agent model editor', () => {
  let app, controller
  beforeEach(async () => {
    document.body.innerHTML = '<div data-controller="comment-agent-model" data-comment-agent-model-url-value="/users/9/agent-model"><div data-popup-menu-target="menu"></div></div>'
    app = Application.start()
    app.register('comment-agent-model', Controller)
    await tick()
    controller = app.getControllerForElementAndIdentifier(document.body.firstChild, 'comment-agent-model')
    global.fetch = jest.fn()
  })
  afterEach(() => { app.stop(); document.body.innerHTML = ''; jest.restoreAllMocks() })
  test('loads fresh settings on every open', async () => {
    fetch.mockResolvedValue({ headers: new Headers(), ok: true, text: async () => editor })
    await controller.load()
    expect(controller.editor.querySelector('input').value).toBe('opus')
    await controller.load()
    expect(fetch).toHaveBeenCalledTimes(2)
  })
  test('repositions the open popup after loading its form', () => {
    const popup = { isOpen: () => true, place: jest.fn() }
    jest.spyOn(app, 'getControllerForElementAndIdentifier').mockReturnValue(popup)
    controller.renderEditor(editor)
    expect(popup.place).toHaveBeenCalled()
  })
  test('no editor for forbidden requests and failed loads can retry', async () => {
    fetch.mockResolvedValueOnce({ headers: new Headers(), ok: false }).mockRejectedValueOnce(new Error('offline'))
    await controller.load()
    await controller.load()
    expect(document.querySelector('form')).toBeNull()
    expect(controller.loading).toBe(false)
  })
  test('saves agent defaults without sending or changing the chat override', async () => {
    controller.editor.innerHTML = editor
    const chat = document.createElement('input')
    chat.name = 'comment[agent_run_options][reasoning_effort]'
    chat.value = 'high'
    document.body.appendChild(chat)
    fetch.mockResolvedValue({ headers: new Headers(), ok: true, text: async () => '<p role="status">Saved</p>' })
    await controller.save({ target: document.querySelector('form'), preventDefault() {}, stopPropagation() {} })
    const [url, request] = fetch.mock.calls[0]
    expect(url).toBe('/users/9/agent-model')
    expect(request.method).toBe('PATCH')
    expect(request.body.get('user[llm_model]')).toBe('opus')
    expect(request.body.get('user[reasoning_effort]')).toBe('low')
    expect(request.body.has(chat.name)).toBe(false)
    expect(chat.value).toBe('high')
    expect(controller.editor.textContent).toBe('Saved')
  })
  test.each([422, 403, 500, 'network'])('handles failure %s without false success', async status => {
    controller.editor.innerHTML = editor
    const form = document.querySelector('form')
    if (status === 'network') fetch.mockRejectedValue(new Error('offline'))
    else fetch.mockResolvedValue({ headers: new Headers(), ok: false, status, text: async () => '<p role="status">Invalid model</p>' })
    await controller.save({ target: form, preventDefault() {}, stopPropagation() {} })
    expect(controller.editor.querySelector('[role="status"]').textContent).toBe(status === 422 ? 'Invalid model' : 'Save failed')
    expect(form.querySelector('[type="submit"]').disabled).toBe(false)
  })
  test('model edits and suggestions refresh efforts without changing the chat override', async () => {
    controller.editor.innerHTML = editor
    const form = controller.editor.querySelector('form')
    form.dataset.action = 'input->comment-agent-model#modelChanged change->comment-agent-model#modelChanged'
    const model = form.querySelector('input')
    const select = form.querySelector('select')
    select.dataset.efforts = JSON.stringify({ codex: ['minimal', 'low'], claude: ['low', 'max'], codex_custom: ['high'] })
    select.innerHTML = '<option value="">Default</option><option value="minimal" selected>minimal</option>'
    const chat = document.createElement('input')
    chat.name = 'comment[agent_run_options][reasoning_effort]'
    chat.value = 'high'
    document.body.appendChild(chat)
    await tick()
    model.value = ' paperclip/claude_local/opus '
    model.dispatchEvent(new Event('input', { bubbles: true }))
    expect([...select.options].map(option => option.value)).toEqual(['', 'low', 'max'])
    expect(select.value).toBe('')
    expect(select.options[0].text).toBe('Default')
    select.value = 'low'
    model.value = 'paperclip/codex_local'
    model.dispatchEvent(new Event('change', { bubbles: true }))
    expect(select.value).toBe('low')
    expect([...select.options].map(option => option.value)).toEqual(['', 'minimal', 'low'])
    select.value = 'minimal'
    select.dispatchEvent(new Event('change', { bubbles: true }))
    expect(select.value).toBe('minimal')
    model.value = 'paperclip/codex_custom'
    model.dispatchEvent(new Event('change', { bubbles: true }))
    expect([...select.options].map(option => option.value)).toEqual(['', 'high'])
    model.value = 'unknown'
    model.dispatchEvent(new Event('input', { bubbles: true }))
    expect([...select.options].map(option => option.value)).toEqual([''])
    expect(select.value).toBe('')
    expect(chat.value).toBe('high')
    select.remove()
    expect(() => controller.modelChanged({ target: model })).not.toThrow()
    expect(fetch).not.toHaveBeenCalled()
  })
  test('clicks inside the editor leave the avatar popup open', () => {
    const event = { stopPropagation: jest.fn() }
    controller.keepOpen(event)
    expect(event.stopPropagation).toHaveBeenCalled()
  })
  test('dynamic participant menus enable editing only for AI agents', () => {
    const labels = { open: 'Open %{name}', online: 'Online', offline: 'Offline' }
    for (const ai of [true, false]) {
      const menu = createUserMenu({ user: { id: 9, name: 'Agent', profile_url: '/users/9', ai_user: ai }, labels, menuId: 'participant-9' })
      expect(menu.dataset.controller.includes('comment-agent-model')).toBe(ai)
      expect(menu.querySelector('button').dataset.action.includes('comment-agent-model#load')).toBe(ai)
    }
  })
})
