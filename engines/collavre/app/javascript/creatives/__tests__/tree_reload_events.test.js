/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { listenForTreeReloads } from '../tree_reload_events'

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

  test('nothing is heard once stopped', () => {
    stop()

    document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
    document.dispatchEvent(new CustomEvent('creative-sync:release'))
    dropCompleted({ creativeIds: ['2'] })

    expect(reload).not.toHaveBeenCalled()
    expect(release).not.toHaveBeenCalled()
  })
})
