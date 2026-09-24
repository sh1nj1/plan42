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
  const switchTopic = (topicId) => popup.dispatchEvent(
    new CustomEvent('comments--topics:change', { detail: { topicId } })
  )

  beforeEach(async () => {
    localStorage.clear()
    document.body.innerHTML = FIXTURE
    popup = document.getElementById('comments-popup')
    application = Application.start()
    application.register('comments--run-options', RunOptionsController)
    await tick()
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
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

    expect(JSON.parse(localStorage.getItem(`${STORAGE_PREFIX}7`)))
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
    effort().value = 'max'
    effort().dispatchEvent(new Event('change'))
    popup.querySelector('.reset').click()

    expect(effort().value).toBe('')
    expect(localStorage.getItem(`${STORAGE_PREFIX}main`)).toBeNull()
  })

  test('ignores unreadable storage and unknown stored efforts', () => {
    localStorage.setItem(`${STORAGE_PREFIX}9`, '{broken')
    switchTopic(9)
    expect(effort().value).toBe('')

    localStorage.setItem(`${STORAGE_PREFIX}10`, JSON.stringify({ reasoning_effort: 'turbo' }))
    switchTopic(10)
    expect(effort().value).toBe('')
  })

  test('keeps working when storage throws', () => {
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
