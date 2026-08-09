/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { applyRowProperties } from '../tree_renderer'

test('marks onboarding rows so destructive controls can protect them', () => {
  const row = document.createElement('div')

  applyRowProperties(row, { id: 42, onboarding_item: true, templates: {} })

  expect(row.onboardingItem).toBe(true)
  expect(row.hasAttribute('onboarding-item')).toBe(true)
})

test('realtime onboarding updates refresh the request-aware card component', () => {
  const row = document.createElement('div')
  row.creativeId = 42
  row._refreshOnboardingCard = jest.fn().mockResolvedValue(undefined)

  applyRowProperties(row, {
    id: 42,
    refresh_onboarding_description: true,
    templates: {},
  })

  expect(row._refreshOnboardingCard).toHaveBeenCalledWith(42)
})

test('ordinary realtime updates do not fetch the onboarding component', () => {
  const row = document.createElement('div')
  row.creativeId = 42
  row._refreshOnboardingCard = jest.fn()

  applyRowProperties(row, { id: 42, templates: {} })

  expect(row._refreshOnboardingCard).not.toHaveBeenCalled()
})
