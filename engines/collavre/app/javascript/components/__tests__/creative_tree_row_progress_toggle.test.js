/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

const csrfFetch = jest.fn()

jest.unstable_mockModule('../../lib/api/csrf_fetch', () => ({
  default: csrfFetch,
}))

beforeAll(() => {
  if (typeof globalThis.customElements === 'undefined') {
    globalThis.customElements = window.customElements
  }
})

async function mountRow(progressHtml) {
  await import('../creative_tree_row.js')
  const row = document.createElement('creative-tree-row')
  row.creativeId = '7'
  row.progressHtml = progressHtml
  document.body.appendChild(row)
  await row.updateComplete
  return row
}

const INCOMPLETE_TOGGLE = '<span class="progress-toggle-wrap" data-progress-toggle="true" data-creative-id="7" data-current-progress="0" data-new-progress="1" data-mark-complete="Mark complete" data-mark-incomplete="Mark incomplete" title="Mark complete"><input type="checkbox" class="progress-toggle-checkbox" aria-label="Mark complete"><span class="progress-toggle-mark" aria-hidden="true"> </span></span>'

const COMPLETE_TOGGLE = INCOMPLETE_TOGGLE
  .replace('data-current-progress="0" data-new-progress="1"', 'data-current-progress="1" data-new-progress="0"')
  .replace('title="Mark complete"', 'title="Mark incomplete"')
  .replace('<input type="checkbox"', '<input type="checkbox" checked')
  .replace('aria-label="Mark complete"', 'aria-label="Mark incomplete"')

afterEach(() => {
  csrfFetch.mockReset()
  document.body.innerHTML = ''
})

test('updates checkbox metadata and ancestor progress after a successful toggle', async () => {
  csrfFetch.mockResolvedValue({
    ok: true,
    json: async () => ({
      progress: 1,
      progress_html: INCOMPLETE_TOGGLE.replace('data-current-progress="0"', 'data-current-progress="1"'),
      has_children: false,
      ancestors: [{
        id: '42',
        progress: 0.5,
        progress_html: '<span class="creative-progress-incomplete">50%</span>',
      }],
    }),
  })
  const ancestor = document.createElement('creative-tree-row')
  ancestor.setAttribute('creative-id', '42')
  document.body.appendChild(ancestor)
  const row = await mountRow(INCOMPLETE_TOGGLE)

  row.querySelector('[data-progress-toggle]').click()
  await Promise.resolve()
  await row.updateComplete

  expect(csrfFetch).toHaveBeenCalledWith('/creatives/7', expect.objectContaining({ method: 'PATCH' }))
  expect(row.dataset.progressValue).toBe('1')
  expect(ancestor.progressHtml).toContain('50%')
})

test('flips the completion state optimistically so the mark shows before the request settles', async () => {
  let resolveFetch
  csrfFetch.mockReturnValue(new Promise((resolve) => { resolveFetch = resolve }))
  const row = await mountRow(INCOMPLETE_TOGGLE)
  const toggle = row.querySelector('[data-progress-toggle]')

  toggle.click()

  // CSS keys the mark/checkbox swap off data-current-progress, so the completed
  // row reads as done immediately instead of waiting on the PATCH.
  expect(toggle.dataset.currentProgress).toBe('1')
  expect(toggle.dataset.newProgress).toBe('0')
  expect(toggle.title).toBe('Mark incomplete')
  expect(toggle.querySelector('.progress-toggle-mark')).not.toBeNull()

  resolveFetch({ ok: true, json: async () => ({ progress: 1 }) })
  await Promise.resolve()
  await row.updateComplete
})

// Space (and a click landing on the box itself) runs the input's own activation:
// the browser flips `checked` before the click reaches this handler. Reading the
// checkbox instead of the dataset would invert the state back while the PATCH is
// in flight, so a completed row would still read as checked. `checkbox.click()`
// drives the same activation path Space does — jsdom has no Space-to-click
// default action. Its canceled-activation restore inverts the current value
// where browsers reassign the saved one, so the browser-faithful check lives in
// test/system/creative_progress_toggle_keyboard_test.rb.
test('unchecks the box when the completed checkbox itself is activated', async () => {
  let resolveFetch
  csrfFetch.mockReturnValue(new Promise((resolve) => { resolveFetch = resolve }))
  const row = await mountRow(COMPLETE_TOGGLE)
  const toggle = row.querySelector('[data-progress-toggle]')
  const checkbox = toggle.querySelector('input')

  checkbox.click()

  expect(toggle.dataset.currentProgress).toBe('0')
  expect(toggle.dataset.newProgress).toBe('1')
  expect(checkbox.checked).toBe(false)

  resolveFetch({ ok: true, json: async () => ({ progress: 0 }) })
  await Promise.resolve()
  await row.updateComplete
})

test('rolls the box back to unchecked when activating it directly fails', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => {})
  csrfFetch.mockResolvedValue({ ok: false, status: 422 })
  const row = await mountRow(INCOMPLETE_TOGGLE)
  const toggle = row.querySelector('[data-progress-toggle]')
  const checkbox = toggle.querySelector('input')

  checkbox.click()
  await Promise.resolve()
  await row.updateComplete

  expect(toggle.dataset.currentProgress).toBe('0')
  expect(checkbox.checked).toBe(false)
})

test('restores checkbox metadata when a toggle request fails', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => {})
  csrfFetch.mockResolvedValue({ ok: false, status: 422 })
  const row = await mountRow(INCOMPLETE_TOGGLE)
  const toggle = row.querySelector('[data-progress-toggle]')

  toggle.click()
  await Promise.resolve()
  await row.updateComplete

  expect(toggle.dataset.currentProgress).toBe('0')
  expect(toggle.dataset.newProgress).toBe('1')
  expect(toggle.title).toBe('Mark complete')
  expect(toggle.querySelector('input').getAttribute('aria-label')).toBe('Mark complete')
})
