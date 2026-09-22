/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

jest.unstable_mockModule('../creative_link_picker', () => ({
  openCreativeLinkPicker: jest.fn(),
}))

await import('../command_menu')

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))
// flush() plus the placement frame CommonPopup defers its reveal to.
const settle = () => flush().then(() => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0))))

const COMMANDS = [
  { name: 'task_create', label: '/task_create', aliases: [] },
  { name: 'topic_list', label: '/topic_list', aliases: [] },
]

// The command list is fetched on every input event, so the menu's behaviour while
// a lookup is in flight is what the user actually sees when typing "/task".
describe('command menu typeahead', () => {
  const originalFetch = global.fetch

  const setup = () => {
    document.body.innerHTML = `
      <form id="new-comment-form"><textarea></textarea></form>
      <div id="comments-popup" data-creative-id="7"></div>
      <div id="command-menu" style="display:none">
        <ul data-popup-list></ul>
      </div>
    `
    document.dispatchEvent(new Event('turbo:load'))
    return {
      textarea: document.querySelector('textarea'),
      menu: document.getElementById('command-menu'),
    }
  }

  const type = (textarea, value) => {
    textarea.value = value
    textarea.setSelectionRange(value.length, value.length)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
  }

  afterEach(() => {
    document.body.innerHTML = ''
    global.fetch = originalFetch
    jest.clearAllMocks()
  })

  test('shares one request across the keystrokes typed before it resolves', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))
    const { textarea, menu } = setup()

    for (const value of ['/', '/t', '/ta', '/tas', '/task']) type(textarea, value)
    expect(global.fetch).toHaveBeenCalledTimes(1)

    resolveFetch({ ok: true, json: () => Promise.resolve(COMMANDS) })
    await flush()

    expect(menu.style.display).toBe('block')
    // Only the query the user actually ended on is rendered.
    expect(menu.querySelectorAll('.common-popup-item')).toHaveLength(1)
    expect(menu.textContent).toContain('/task_create')
  })

  test('a failed lookup is not cached, so the next keystroke retries', async () => {
    global.fetch = jest.fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve(COMMANDS) })
    const { textarea, menu } = setup()

    type(textarea, '/')
    await flush()
    expect(menu.style.display).toBe('none')

    type(textarea, '/t')
    await flush()
    expect(global.fetch).toHaveBeenCalledTimes(2)
    expect(menu.style.display).toBe('block')
  })

  test('a lookup that lands after the "/" is deleted does not re-open the menu', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))
    const { textarea, menu } = setup()

    type(textarea, '/')
    // The user backspaces before the command list arrives.
    type(textarea, '')

    resolveFetch({ ok: true, json: () => Promise.resolve(COMMANDS) })
    await flush()

    expect(menu.style.display).toBe('none')
  })

  test('a stale lookup cannot overwrite the menu with an outdated query', async () => {
    const pending = []
    global.fetch = jest.fn(() => new Promise((resolve) => { pending.push(resolve) }))
    const { textarea, menu } = setup()

    type(textarea, '/')
    // Second keystroke reuses the in-flight request, so there is still only one.
    type(textarea, '/topic')
    expect(pending).toHaveLength(1)

    pending[0]({ ok: true, json: () => Promise.resolve(COMMANDS) })
    await flush()

    // Rendered for "/topic", not for the earlier empty query that would have
    // listed every command.
    expect(menu.querySelectorAll('.common-popup-item')).toHaveLength(1)
    expect(menu.textContent).toContain('/topic_list')
  })

  test('the popup is not blanked between keystrokes once it is open', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve(COMMANDS) })
    const { textarea, menu } = setup()

    type(textarea, '/')
    // Let the placement frame reveal the popup, as it does for a real first open.
    await settle()
    expect(menu.style.visibility).toBe('visible')

    // Every later keystroke must leave it on screen: blanking it here is what
    // made the menu blink once per character.
    for (const value of ['/t', '/ta', '/tas']) {
      type(textarea, value)
      await flush()
      expect(menu.style.visibility).toBe('visible')
    }
  })

  test('command arguments refocus after settlement without stealing deliberate focus', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{
        name: 'task_create',
        label: '/task_create',
        aliases: [],
        input_schema: [{ name: 'title', type: 'string', required: false }],
      }]),
    })
    const { textarea, menu } = setup()
    const submit = document.createElement('button')
    const submitClick = jest.fn()
    let submissionId
    submit.type = 'button'
    submit.setAttribute('data-comments--form-target', 'submit')
    submit.addEventListener('click', (event) => {
      submitClick()
      submissionId = event.commandSubmissionId
      document.getElementById('comments-popup').dispatchEvent(
        new CustomEvent('comments--form:submit-started', { detail: { submissionId } }),
      )
    })
    document.getElementById('new-comment-form').appendChild(submit)

    type(textarea, '/task')
    await settle()
    textarea.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter',
      bubbles: true,
      cancelable: true,
    }))

    const titleInput = document.querySelector('#command-args-dialog textarea')
    titleInput.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter',
      bubbles: true,
      cancelable: true,
    }))
    await flush()

    expect(document.getElementById('command-args-dialog')).toBeNull()
    expect(menu.style.display).toBe('none')
    expect(submitClick).toHaveBeenCalledTimes(1)
    expect(document.activeElement).not.toBe(textarea)

    document.getElementById('comments-popup').dispatchEvent(
      new CustomEvent('comments--form:submit-settled', {
        detail: { submissionId: 'an-unrelated-send' },
      }),
    )
    expect(document.activeElement).not.toBe(textarea)

    document.getElementById('comments-popup').dispatchEvent(
      new CustomEvent('comments--form:submit-settled', { detail: { submissionId } }),
    )

    expect(document.activeElement).toBe(textarea)

    type(textarea, '/task')
    await settle()
    textarea.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter',
      bubbles: true,
      cancelable: true,
    }))
    document.querySelector('#command-args-dialog textarea').dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter',
      bubbles: true,
      cancelable: true,
    }))
    await flush()

    const otherControl = document.createElement('button')
    document.body.appendChild(otherControl)
    otherControl.focus()
    document.getElementById('comments-popup').dispatchEvent(
      new CustomEvent('comments--form:submit-settled', { detail: { submissionId } }),
    )

    expect(submitClick).toHaveBeenCalledTimes(2)
    expect(document.activeElement).toBe(otherControl)
  })

  test('a rejected command submission removes its settlement listener', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{
        name: 'task_create',
        label: '/task_create',
        aliases: [],
        input_schema: [{ name: 'title', type: 'string', required: false }],
      }]),
    })
    const { textarea } = setup()
    const submit = document.createElement('button')
    let rejectedSubmissionId
    submit.type = 'button'
    submit.setAttribute('data-comments--form-target', 'submit')
    submit.addEventListener('click', (event) => {
      rejectedSubmissionId = event.commandSubmissionId
      // No submit-started event: the form controller rejected this attempt.
    })
    document.getElementById('new-comment-form').appendChild(submit)

    type(textarea, '/task')
    await settle()
    textarea.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter', bubbles: true, cancelable: true,
    }))
    document.querySelector('#command-args-dialog textarea').dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter', bubbles: true, cancelable: true,
    }))
    await flush()

    expect(document.activeElement).toBe(textarea)

    const otherControl = document.createElement('button')
    document.body.appendChild(otherControl)
    otherControl.focus()
    document.getElementById('comments-popup').dispatchEvent(
      new CustomEvent('comments--form:submit-settled', {
        detail: { submissionId: rejectedSubmissionId },
      }),
    )

    expect(document.activeElement).toBe(otherControl)
  })
})
