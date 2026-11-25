/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { listenForTreeReloads, listIsFiltered } from '../tree_reload_events'

function mountList(url) {
  document.body.innerHTML = url === undefined ? '' : `<div id="creatives" data-creatives--tree-url-value="${url}"></div>`
}

afterEach(() => mountList(undefined))

describe('listIsFiltered', () => {
  test.each([
    ['no list on the page', undefined, false],
    ['a list with no URL', '', false],
    ['a plain list', '/creatives?id=5&show_archived=true', false],
    ['a blank filter param', '/creatives?id=5&search=&tags[]=', false],
    ['a tag filter', '/creatives?tags[]=3', true],
    ['a progress filter', '/creatives?id=5&min_progress=0&max_progress=0.99', true],
    ['a comment filter', '/creatives?comment=true', true],
    ['a search', '/creatives?search=report', true],
  ])('%s', (_name, url, filtered) => {
    mountList(url)

    expect(listIsFiltered()).toBe(filtered)
  })
})

function dropCompleted(detail) {
  window.dispatchEvent(new CustomEvent('collavre:creative-drop-complete', { detail }))
}

describe('listenForTreeReloads', () => {
  let reload
  let release
  let stop

  beforeEach(() => {
    reload = jest.fn()
    release = jest.fn()
    stop = listenForTreeReloads({ reload, release })
  })

  afterEach(() => stop())

  test('a refetch request reloads', () => {
    document.dispatchEvent(new CustomEvent('creative-sync:refetch'))

    expect(reload).toHaveBeenCalledTimes(1)
    expect(release).not.toHaveBeenCalled()
  })

  // The row already shows what was saved, so a settled save only lets a reload
  // that was waiting on it go ahead.
  test('a settled save releases without reloading', () => {
    document.dispatchEvent(new CustomEvent('creative-sync:release'))

    expect(release).toHaveBeenCalledTimes(1)
    expect(reload).not.toHaveBeenCalled()
  })

  test('a drop the list rendered in place does not reload', () => {
    dropCompleted({ creativeIds: ['2'], context: 'target', rendered: true })

    expect(reload).not.toHaveBeenCalled()
  })

  test.each([
    ['the list did not render', { creativeIds: ['2'], context: 'target', rendered: false }],
    ['from another tree or window', { creativeIds: ['2'], context: 'source' }],
    ['with no detail', undefined],
  ])('a drop %s reloads', (_name, detail) => {
    dropCompleted(detail)

    expect(reload).toHaveBeenCalledTimes(1)
  })

  // Which rows a filtered list holds, and the progress they show, come from
  // the filter, so a save or a drop there is only settled by a refetch.
  test('a filtered list reloads after a settled save and after a drop it rendered', () => {
    mountList('/creatives?id=5&min_progress=1')

    document.dispatchEvent(new CustomEvent('creative-sync:release'))
    dropCompleted({ creativeIds: ['2'], context: 'target', rendered: true })

    expect(reload).toHaveBeenCalledTimes(2)
    expect(release).not.toHaveBeenCalled()
  })

  test('nothing is heard once stopped', () => {
    stop()

    document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
    document.dispatchEvent(new CustomEvent('creative-sync:release'))
    dropCompleted({ creativeIds: ['2'] })

    expect(reload).not.toHaveBeenCalled()
    expect(release).not.toHaveBeenCalled()
  })
})
