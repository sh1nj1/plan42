/**
 * @jest-environment jsdom
 */

import { creativePathFromTemplate } from '../creative_path'

describe('creativePathFromTemplate', () => {
  test('preserves a mounted engine prefix', () => {
    expect(creativePathFromTemplate('/collavre/creatives/__CREATIVE_ID__', '42'))
      .toBe('/collavre/creatives/42')
  })

  test('falls back to the root-mounted creative path', () => {
    expect(creativePathFromTemplate(null, '42')).toBe('/creatives/42')
  })
})
