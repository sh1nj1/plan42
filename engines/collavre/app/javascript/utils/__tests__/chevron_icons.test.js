import { CHEVRON_COLLAPSED, CHEVRON_EXPANDED } from '../chevron_icons'

describe('tree chevron icons', () => {
  test('shares consistent SVG attributes and the expected toggle directions', () => {
    const collapsed = document.createElement('template')
    collapsed.innerHTML = CHEVRON_COLLAPSED
    const expanded = document.createElement('template')
    expanded.innerHTML = CHEVRON_EXPANDED

    expect(collapsed.content.querySelector('svg').getAttribute('aria-hidden')).toBe('true')
    expect(collapsed.content.querySelector('path').getAttribute('d')).toBe('M9 6L15 12L9 18')
    expect(expanded.content.querySelector('svg').getAttribute('aria-hidden')).toBe('true')
    expect(expanded.content.querySelector('path').getAttribute('d')).toBe('M6 9L12 15L18 9')
  })
})
