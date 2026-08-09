/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import {
  WORKSPACE_FRAME_ID,
  applyFilterParam,
  buildFilterUrl,
  syncFilterButtons,
  visitFilterUrl
} from '../filter_navigation'

// jsdom's window.location is unforgeable, so drive it through history instead
// of replacing the object.
function setLocation(href) {
  window.history.replaceState({}, '', href)
}

describe('buildFilterUrl', () => {
  test('keeps the current URL and its params when already on the index', () => {
    setLocation('http://localhost/creatives?id=7&search=hi')

    const url = buildFilterUrl({ indexPath: '/creatives', onIndex: true }, (params) => {
      params.set('comment', 'true')
    })

    expect(url.pathname).toBe('/creatives')
    expect(url.searchParams.get('id')).toBe('7')
    expect(url.searchParams.get('search')).toBe('hi')
    expect(url.searchParams.get('comment')).toBe('true')
  })

  test('preserves the root route pathname when the index is served at "/"', () => {
    setLocation('http://localhost/?tags=a')

    const url = buildFilterUrl({ indexPath: '/creatives', onIndex: true }, (params) => {
      params.set('comment', 'true')
    })

    expect(url.pathname).toBe('/')
    expect(url.searchParams.get('tags')).toBe('a')
  })

  test('redirects to the index and drops foreign params when elsewhere', () => {
    setLocation('http://localhost/settings?tab=profile')

    const url = buildFilterUrl({ indexPath: '/creatives', onIndex: false }, (params) => {
      params.set('comment', 'true')
    })

    expect(url.pathname).toBe('/creatives')
    expect(url.searchParams.get('tab')).toBeNull()
    expect(url.searchParams.get('comment')).toBe('true')
  })

  test('falls back to the root path when no index path was provided', () => {
    setLocation('http://localhost/settings')

    const url = buildFilterUrl({ indexPath: '', onIndex: false }, () => {})

    expect(url.pathname).toBe('/')
  })
})

describe('applyFilterParam', () => {
  test('turns the comment filter on when absent', () => {
    const params = new URLSearchParams()
    applyFilterParam(params, 'comment')
    expect(params.get('comment')).toBe('true')
  })

  test('turns the comment filter off when already on', () => {
    const params = new URLSearchParams('comment=true')
    applyFilterParam(params, 'comment')
    expect(params.has('comment')).toBe(false)
  })

  test('sets the complete progress range', () => {
    const params = new URLSearchParams()
    applyFilterParam(params, 'complete')
    expect(params.get('min_progress')).toBe('1')
    expect(params.get('max_progress')).toBe('1')
  })

  test('sets the incomplete progress range', () => {
    const params = new URLSearchParams()
    applyFilterParam(params, 'incomplete')
    expect(params.get('min_progress')).toBe('0')
    expect(params.get('max_progress')).toBe('0.99')
  })

  test('clears the progress range for "all" without touching other filters', () => {
    const params = new URLSearchParams('min_progress=1&max_progress=1&comment=true')
    applyFilterParam(params, 'all')
    expect(params.has('min_progress')).toBe(false)
    expect(params.has('max_progress')).toBe(false)
    expect(params.get('comment')).toBe('true')
  })
})

describe('visitFilterUrl', () => {
  let visit

  beforeEach(() => {
    document.body.innerHTML = ''
    setLocation('http://localhost/creatives')
    visit = jest.fn()
    window.Turbo = { visit }
  })

  afterEach(() => {
    delete window.Turbo
    document.body.innerHTML = ''
  })

  test('replaces only the workspace frame when it is present', () => {
    document.body.innerHTML = `<turbo-frame id="${WORKSPACE_FRAME_ID}"></turbo-frame>`

    const result = visitFilterUrl(new URL('http://localhost/creatives?comment=true'))

    expect(visit).toHaveBeenCalledWith('/creatives?comment=true', {
      action: 'advance',
      frame: WORKSPACE_FRAME_ID
    })
    expect(result).toBe(true)
  })

  test('performs a full Turbo visit when there is no workspace frame', () => {
    const result = visitFilterUrl(new URL('http://localhost/creatives?comment=true'))

    expect(visit).toHaveBeenCalledWith('/creatives?comment=true', { action: 'advance' })
    expect(result).toBe(false)
  })

  test('omits the query string entirely when no filters remain', () => {
    visitFilterUrl(new URL('http://localhost/creatives'))

    expect(visit).toHaveBeenCalledWith('/creatives', { action: 'advance' })
  })
})

describe('syncFilterButtons', () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <button data-filter-state="any-filter" class="active"></button>
      <button data-filter-state="progress:all"></button>
      <button data-filter-state="progress:incomplete" class="active"></button>
      <button data-filter-state="progress:complete"></button>
      <button data-filter-state="comment"></button>
      <button data-filter-state="archived" data-label-on="Hide archived" data-label-off="Show archived">Show archived</button>
    `
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  function activeStates() {
    return Array.from(document.querySelectorAll('[data-filter-state].active')).map(
      (el) => el.dataset.filterState
    )
  }

  test('activates the comment button and resets a stale progress selection', () => {
    syncFilterButtons(new URL('http://localhost/creatives?comment=true'))

    expect(activeStates().sort()).toEqual(['comment', 'progress:all'])
  })

  test('does not treat the comment filter as a generic "any filter"', () => {
    syncFilterButtons(new URL('http://localhost/creatives?comment=true'))

    expect(document.querySelector('[data-filter-state="any-filter"]').classList).not.toContain(
      'active'
    )
  })

  test('marks the search trigger active for progress, archive and search filters', () => {
    syncFilterButtons(new URL('http://localhost/creatives?min_progress=1&max_progress=1'))
    expect(activeStates()).toContain('any-filter')

    syncFilterButtons(new URL('http://localhost/creatives?show_archived=true'))
    expect(activeStates()).toContain('any-filter')

    syncFilterButtons(new URL('http://localhost/creatives?search=abc'))
    expect(activeStates()).toContain('any-filter')
  })

  test('ignores blank filter values, matching the server-side .present? check', () => {
    syncFilterButtons(new URL('http://localhost/creatives?search=&min_progress='))

    expect(activeStates()).toEqual(['progress:all'])
  })

  test('recognizes the incomplete progress range', () => {
    syncFilterButtons(new URL('http://localhost/creatives?min_progress=0&max_progress=0.99'))

    expect(activeStates().sort()).toEqual(['any-filter', 'progress:incomplete'])
  })

  test('swaps the archive button label along with its active state', () => {
    const button = document.querySelector('[data-filter-state="archived"]')

    syncFilterButtons(new URL('http://localhost/creatives?show_archived=true'))
    expect(button.textContent).toBe('Hide archived')

    syncFilterButtons(new URL('http://localhost/creatives'))
    expect(button.textContent).toBe('Show archived')
  })
})
