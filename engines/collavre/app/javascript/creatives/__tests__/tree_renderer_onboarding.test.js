/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { applyRowProperties } from '../tree_renderer'

afterEach(() => {
  document.body.innerHTML = ''
})

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

test('realtime navigation updates preserve the member update URL', () => {
  const row = document.createElement('div')
  row.linkUrl = '/collavre/creatives/42'
  row.updateUrl = '/collavre/creatives/42'
  row.setAttribute('update-url', row.updateUrl)

  applyRowProperties(row, {
    id: 42,
    link_url: '/creatives?id=42',
    templates: {},
  })

  expect(row.linkUrl).toBe('/creatives?id=42')
  expect(row.updateUrl).toBe('/collavre/creatives/42')
  expect(row.getAttribute('update-url')).toBe('/collavre/creatives/42')
})

test('realtime-created rows derive a mounted member update URL from the form template', () => {
  document.body.innerHTML = `
    <form id="inline-edit-form-element"
          data-update-url-template="/collavre/creatives/__CREATIVE_ID__"></form>
  `
  const row = document.createElement('div')
  row.updateUrl = '#'

  applyRowProperties(row, {
    id: 42,
    link_url: '/creatives?id=42',
    templates: {},
  })

  expect(row.updateUrl).toBe('/collavre/creatives/42')
  expect(row.getAttribute('update-url')).toBe('/collavre/creatives/42')
})

test('tree payloads apply their explicit member update URL', () => {
  const row = document.createElement('div')

  applyRowProperties(row, {
    id: 42,
    link_url: '/collavre/creatives/42',
    update_url: '/collavre/creatives/42',
    templates: {},
  })

  expect(row.updateUrl).toBe('/collavre/creatives/42')
  expect(row.getAttribute('update-url')).toBe('/collavre/creatives/42')
})
