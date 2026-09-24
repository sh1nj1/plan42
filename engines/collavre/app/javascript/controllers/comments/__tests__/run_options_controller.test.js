/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import RunOptionsController, { STORAGE_PREFIX } from '../run_options_controller'

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms))

describe('comments--run-options', () => {
  let application
  let popup

  const FIXTURE = `
    <div id="comments-popup">
      <form data-controller="comments--run-options" data-action="reset->comments--run-options#afterReset">
        <button type="button" data-comments--run-options-target="toggle"
                data-action="click->comments--run-options#toggle" aria-expanded="false">⚙</button>
        <div data-comments--run-options-target="panel" hidden>
          <select name="comment[agent_run_options][reasoning_effort]" data-comments--run-options-target="effort"
                  data-action="change->comments--run-options#change">
            <option value="">Agent default</option>
            <option value="high">high</option>
            <option value="max">max</option>
          </select>
          <input name="comment[agent_run_options][model]" data-comments--run-options-target="model"
                 data-action="change->comments--run-options#change">
          <button type="button" class="reset" data-action="click->comments--run-options#reset">Reset</button>
        </div>
      </form>
    </div>`

  const form = () => popup.querySelector('form')
  const effort = () => popup.querySelector('select')
  const model = () => popup.querySelector('input')
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
    await tick()
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
    delete document.body.dataset.currentUserId
  })

  test('isolates accounts and ignores legacy unscoped options', () => {
    localStorage.setItem(`${STORAGE_PREFIX}7`, JSON.stringify({ reasoning_effort: 'max' }))
    switchTopic(7)
    expect(effort().value).toBe('')
    effort().value = 'high'
    model().value = 'opus'
    effort().dispatchEvent(new Event('change'))
    document.body.dataset.currentUserId = '2'
    switchTopic(7)
    expect(effort().value).toBe('')
    expect(model().value).toBe('')
    model().value = 'sonnet'
    model().dispatchEvent(new Event('change'))
    document.body.dataset.currentUserId = '1'
    switchTopic(7)
    expect(effort().value).toBe('high')
    expect(model().value).toBe('opus')
  })

  test('does not persist without a signed-in user', () => {
    delete document.body.dataset.currentUserId
    switchTopic(7)
    effort().value = 'high'
    effort().dispatchEvent(new Event('change'))
    expect(localStorage.length).toBe(0)
  })

  test('toggles the panel', () => {
    toggle().click()
    expect(popup.querySelector('[data-comments--run-options-target="panel"]').hidden).toBe(false)
    expect(toggle().getAttribute('aria-expanded')).toBe('true')
    toggle().click()
    expect(popup.querySelector('[data-comments--run-options-target="panel"]').hidden).toBe(true)
  })

  test('remembers the choice per topic and restores it on switch', () => {
    switchTopic(7)
    effort().value = 'high'
    model().value = ' paperclip/claude_local/opus '
    effort().dispatchEvent(new Event('change'))

    expect(JSON.parse(localStorage.getItem(`${STORAGE_PREFIX}7:user:1`)))
      .toEqual({ reasoning_effort: 'high', model: 'paperclip/claude_local/opus' })
    expect(toggle().classList.contains('active')).toBe(true)

    switchTopic(8)
    expect(effort().value).toBe('')
    expect(model().value).toBe('')
    expect(toggle().classList.contains('active')).toBe(false)

    switchTopic(7)
    expect(effort().value).toBe('high')
    expect(model().value).toBe('paperclip/claude_local/opus')
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
    popup.querySelector('.reset').click()

    expect(effort().value).toBe('')
    expect(localStorage.getItem(`${STORAGE_PREFIX}7:user:1`)).toBeNull()
  })

  test('the full-message view uses the main topic, so creatives do not share a choice', () => {
    switchTopic('', 100)
    effort().value = 'max'
    model().value = 'paperclip/claude_local/opus'
    effort().dispatchEvent(new Event('change'))
    expect(JSON.parse(localStorage.getItem(`${STORAGE_PREFIX}100:user:1`)))
      .toEqual({ reasoning_effort: 'max', model: 'paperclip/claude_local/opus' })

    // Another creative's full-message view starts from the agent defaults.
    switchTopic('', 200)
    expect(effort().value).toBe('')
    expect(model().value).toBe('')

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
