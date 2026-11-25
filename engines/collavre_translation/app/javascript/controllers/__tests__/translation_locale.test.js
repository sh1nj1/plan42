/** @jest-environment jsdom */
import { translationLocaleUrl } from '../translation_locale'

beforeEach(() => window.history.replaceState({}, '', '/creatives?id=42'))

test('preserves requests without an override', () => {
  expect(translationLocaleUrl('/translation/creatives/42/translation?embed=0')).toBe('/translation/creatives/42/translation?embed=0')
})

test('propagates lang and preserves existing query parameters', () => {
  window.history.replaceState({}, '', '/creatives?id=42&lang=ko-KR')
  expect(translationLocaleUrl('/translation/creatives/42/translation?embed=0')).toBe('/translation/creatives/42/translation?embed=0&lang=ko-KR')
  expect(translationLocaleUrl('/translation/comments/1/translation')).toBe('/translation/comments/1/translation?lang=ko-KR')
})
