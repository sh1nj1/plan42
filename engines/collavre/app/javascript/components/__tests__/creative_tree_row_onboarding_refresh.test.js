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

afterEach(() => {
  document.body.innerHTML = ''
  csrfFetch.mockReset()
})

test('progress completion refreshes both the onboarding step and overview rows', async () => {
  await import('../creative_tree_row.js')
  const row = document.createElement('creative-tree-row')
  row.linkUrl = '/creatives?id=7'
  row.updateUrl = '/collavre/creatives/7'
  document.body.appendChild(row)
  const refresh = jest.spyOn(row, '_refreshOnboardingCard').mockResolvedValue()
  const toggle = document.createElement('button')
  toggle.dataset.creativeId = '7'
  toggle.dataset.newProgress = '1'
  csrfFetch.mockResolvedValue({
    ok: true,
    json: () => Promise.resolve({
      onboarding_card_id: 42,
      onboarding_root_id: 84,
    }),
  })

  await row._handleProgressToggle({
    preventDefault: jest.fn(),
    stopPropagation: jest.fn(),
    currentTarget: toggle,
  })

  expect(csrfFetch).toHaveBeenCalledWith('/collavre/creatives/7', expect.objectContaining({
    method: 'PATCH',
  }))
  expect(refresh.mock.calls.map(([id]) => id)).toEqual([42, 84])
})

test('realtime-created onboarding rows refresh through their mounted member URL', async () => {
  await import('../creative_tree_row.js')
  const { applyRowProperties, createRow } = await import('../../creatives/tree_renderer.js')
  document.body.innerHTML = `
    <form id="inline-edit-form-element"
          data-update-url-template="/collavre/creatives/__CREATIVE_ID__"></form>
  `
  const row = createRow({
    id: 42,
    link_url: '/creatives?id=42',
    onboarding_item: true,
    templates: { description_html: 'Waiting' },
  })
  document.body.appendChild(row)
  csrfFetch.mockResolvedValue({
    ok: true,
    json: () => Promise.resolve({
      description: 'Completed',
      progress: 1,
      progress_html: '<span class="creative-progress-complete">100%</span>',
    }),
  })

  applyRowProperties(row, {
    id: 42,
    refresh_onboarding_description: true,
    templates: {},
  })
  await new Promise((resolve) => setTimeout(resolve, 0))

  expect(row.linkUrl).toBe('/creatives?id=42')
  expect(row.updateUrl).toBe('/collavre/creatives/42')
  expect(csrfFetch).toHaveBeenCalledWith('/collavre/creatives/42', {
    headers: { Accept: 'application/json' },
  })
  expect(row.descriptionHtml).toBe('Completed')
  expect(row.progressHtml).toBe('<span class="creative-progress-complete">100%</span>')
  expect(row.dataset.progressHtml).toBe('<span class="creative-progress-complete">100%</span>')
  expect(row.dataset.progressValue).toBe('1')
})
