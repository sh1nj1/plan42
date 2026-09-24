/**
 * @jest-environment jsdom
 */

import AvatarModelController from '../../comment_agent_model_controller'
import { Application } from '@hotwired/stimulus'
import RunOptionsController, { STORAGE_PREFIX } from '../run_options_controller'

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms))

describe('comments--run-options', () => {
  let application
  let popup

  const FIXTURE = `
    <div id="comments-popup">
      <div data-controller="comment-agent-model">
        <button type="button" data-thinking-toggle data-action="click->comment-agent-model#thinking keydown->comment-agent-model#thinkingKeydown">Thinking for this message</button>
      </div>
      <form data-controller="comments--run-options" data-action="reset->comments--run-options#afterReset">
        <button type="button" data-comments--run-options-target="toggle"
                data-action="click->comments--run-options#toggle keydown->comments--run-options#keydown mousedown->comments--run-options#keepOpen touchstart->comments--run-options#keepOpen" aria-expanded="false">⚙</button>
        <div data-comments--run-options-target="panel" style="display:none">
          <select hidden name="comment[agent_run_options][reasoning_effort]" data-comments--run-options-target="effort" data-action="change->comments--run-options#change">
            <option value="">Agent default</option>
            <option value="high">high</option>
            <option value="max">max — Claude only</option>
          </select>
          <p>Chat → agent → local defaults</p><ul data-popup-list></ul>
        </div>
      </form>
    </div>`

  const form = () => popup.querySelector('form')
  const effort = () => popup.querySelector('select')
  const toggle = () => popup.querySelector('[data-comments--run-options-target="toggle"]')
  const switchTopic = (topicId, mainTopicId = null) => popup.dispatchEvent(
    new CustomEvent('comments--topics:change', { detail: { topicId, mainTopicId } })
  )

  beforeEach(async () => {
    localStorage.clear()
    document.body.dataset.currentUserId = '1'
    document.body.innerHTML = FIXTURE
    popup = document.getElementById('comments-popup')
    application = Application.start()
    application.register('comments--run-options', RunOptionsController)
    application.register('comment-agent-model', AvatarModelController)
    await tick()
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    delete document.body.dataset.currentUserId
  })

  test('fills the button from the bottom for each effort without a footer warning', () => {
    const controller = application.getControllerForElementAndIdentifier(form(), 'comments--run-options')
    const levels = { none: 0, minimal: 16, low: 33, medium: 50, high: 67, xhigh: 83, max: 100 }
    Object.entries(levels).forEach(([value, fill]) => {
      if (![...effort().options].some(option => option.value === value)) effort().add(new Option(value, value))
      controller.selectEffort(value)
      expect(toggle().style.getPropertyValue('--thinking-fill')).toBe(`${fill}%`)
      expect(new FormData(form()).get('comment[agent_run_options][reasoning_effort]')).toBe(value)
      expect(popup.querySelector('[role="status"]')).toBeNull()
    })
    controller.selectEffort('')
    expect(toggle().style.getPropertyValue('--thinking-fill')).toBe('0%')
    expect(toggle().title).toBe('Agent default')
  })

  test('avatar opens the shared popup and changes message effort without saving agent settings', () => {
    const avatar = popup.querySelector('[data-thinking-toggle]')
    avatar.click()
    expect(avatar.getAttribute('aria-expanded')).toBe('true')
    expect(popup.querySelectorAll('[data-popup-list] li')).toHaveLength(3)
    avatar.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    avatar.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(effort().value).toBe('high')
    expect(avatar.getAttribute('aria-expanded')).toBe('false')
    expect(avatar.style.getPropertyValue('--thinking-fill')).toBe('67%')
    expect(toggle().style.getPropertyValue('--thinking-fill')).toBe('67%')
    expect(new FormData(form()).get('comment[agent_run_options][reasoning_effort]')).toBe('high')
    expect(new FormData(form()).has('user[reasoning_effort]')).toBe(false)
    avatar.click()
    toggle().click()
    expect(avatar.getAttribute('aria-expanded')).toBe('false')
    expect(toggle().getAttribute('aria-expanded')).toBe('true')
    toggle().dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(toggle().getAttribute('aria-expanded')).toBe('false')
  })

  test('isolates accounts and ignores legacy unscoped options', () => {
    localStorage.setItem(`${STORAGE_PREFIX}7`, JSON.stringify({ reasoning_effort: 'max' }))
    switchTopic(7)
    expect(effort().value).toBe('')
    effort().value = 'high'
    effort().dispatchEvent(new Event('change'))
    document.body.dataset.currentUserId = '2'
    switchTopic(7)
    expect(effort().value).toBe('')
    document.body.dataset.currentUserId = '1'
    switchTopic(7)
    expect(effort().value).toBe('high')
  })

  test('does not persist without a signed-in user', () => {
    delete document.body.dataset.currentUserId
    switchTopic(7)
    effort().value = 'high'
    effort().dispatchEvent(new Event('change'))
    expect(localStorage.length).toBe(0)
  })

  test('ignores stored model overrides', () => {
    localStorage.setItem(`${STORAGE_PREFIX}7:user:1`, JSON.stringify({ model: 'opus', reasoning_effort: 'high' }))
    switchTopic(7)
    expect(effort().value).toBe('high')
    expect(new FormData(form()).has('comment[agent_run_options][model]')).toBe(false)
  })

  test('opens the common list immediately and closes on the same button', async () => {
    toggle().click()
    expect(popup.querySelector('[data-popup-list]').children).toHaveLength(3)
    expect(popup.querySelector('select').hidden).toBe(true)
    await tick(30)
    toggle().dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    expect(toggle().getAttribute('aria-expanded')).toBe('true')
    toggle().click()
    expect(popup.querySelector('[data-comments--run-options-target="panel"]').style.display).toBe('none')
  })

  test('selects a level directly, submits it and marks it when reopened', () => {
    switchTopic(7)
    toggle().click()
    popup.querySelectorAll('[data-popup-list] li')[1].click()
    expect(new FormData(form()).get('comment[agent_run_options][reasoning_effort]')).toBe('high')
    expect(toggle().getAttribute('aria-expanded')).toBe('false')
    toggle().click()
    expect(popup.querySelectorAll('[data-popup-list] li')[1].textContent).toBe('✓ high')
  })

  test('supports keyboard selection and escape without submitting the form', () => {
    toggle().click()
    toggle().dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    toggle().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(effort().value).toBe('high')
    toggle().click()
    toggle().dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(toggle().getAttribute('aria-expanded')).toBe('false')
  })

  test('closes on outside click and topic change', async () => {
    toggle().click()
    await tick(30)
    document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    expect(toggle().getAttribute('aria-expanded')).toBe('false')
    toggle().click()
    switchTopic(8)
    expect(toggle().getAttribute('aria-expanded')).toBe('false')
  })

  test('remembers the choice per topic and restores it on switch', () => {
    switchTopic(7)
    effort().value = 'high'
    effort().dispatchEvent(new Event('change'))

    expect(JSON.parse(localStorage.getItem(`${STORAGE_PREFIX}7:user:1`)))
      .toEqual({ reasoning_effort: 'high' })
    expect(toggle().classList.contains('active')).toBe(true)

    switchTopic(8)
    expect(effort().value).toBe('')
    expect(toggle().classList.contains('active')).toBe(false)

    switchTopic(7)
    expect(effort().value).toBe('high')
  })

  test('refills the fields after the form resets itself on send', async () => {
    effort().value = 'max'
    effort().dispatchEvent(new Event('change'))

    form().reset()
    await tick()

    expect(effort().value).toBe('max')
  })

  test('reset clears the choice and its storage', () => {
    switchTopic(7)
    effort().value = 'max'
    effort().dispatchEvent(new Event('change'))
    toggle().click()
    popup.querySelector('[data-popup-list] li').click()

    expect(effort().value).toBe('')
    expect(localStorage.getItem(`${STORAGE_PREFIX}7:user:1`)).toBeNull()
  })

  test('the full-message view uses the main topic, so creatives do not share a choice', () => {
    switchTopic('', 100)
    effort().value = 'max'
    effort().dispatchEvent(new Event('change'))
    expect(JSON.parse(localStorage.getItem(`${STORAGE_PREFIX}100:user:1`)))
      .toEqual({ reasoning_effort: 'max' })

    // Another creative's full-message view starts from the agent defaults.
    switchTopic('', 200)
    expect(effort().value).toBe('')

    // Selecting the main topic explicitly shares the full-message choice.
    switchTopic(100, 100)
    expect(effort().value).toBe('max')
  })

  test('with no topic at all nothing is stored, but a send keeps the choice', async () => {
    effort().value = 'high'
    effort().dispatchEvent(new Event('change'))
    expect(localStorage.length).toBe(0)

    form().reset()
    await tick()
    expect(effort().value).toBe('high')

    switchTopic('', null)
    expect(effort().value).toBe('')
  })

  test('ignores unreadable storage and unknown stored efforts', () => {
    localStorage.setItem(`${STORAGE_PREFIX}9:user:1`, '{broken')
    switchTopic(9)
    expect(effort().value).toBe('')

    localStorage.setItem(`${STORAGE_PREFIX}10:user:1`, JSON.stringify({ reasoning_effort: 'turbo' }))
    switchTopic(10)
    expect(effort().value).toBe('')
  })

  test('keeps working when storage throws', () => {
    switchTopic(7)
    const setItem = Storage.prototype.setItem
    Storage.prototype.setItem = () => { throw new Error('denied') }
    try {
      effort().value = 'high'
      expect(() => effort().dispatchEvent(new Event('change'))).not.toThrow()
      expect(toggle().classList.contains('active')).toBe(true)
    } finally {
      Storage.prototype.setItem = setItem
    }
  })
})
