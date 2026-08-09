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

  expect(refresh.mock.calls.map(([id]) => id)).toEqual([42, 84])
})
