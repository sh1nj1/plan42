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

const INCOMPLETE_TOGGLE = '<span class="progress-toggle-wrap" data-progress-toggle="true" data-creative-id="7" data-current-progress="0" data-new-progress="1" data-mark-complete="Mark complete" data-mark-incomplete="Mark incomplete" title="Mark complete"><input type="checkbox" class="progress-toggle-checkbox" aria-label="Mark complete"></span>'

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
