/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import CreativeHistoryUndoController from '../creative_history_undo_controller'

describe('CreativeHistoryUndoController', () => {
  let application
  let treeRefresh

  beforeEach(async () => {
    jest.useFakeTimers()
    treeRefresh = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', treeRefresh)
    document.body.innerHTML = `
      <aside data-controller="creative-history-undo"
             data-creative-history-undo-timeout-value="30000">
        <button data-action="creative-history-undo#dismiss">Dismiss</button>
      </aside>`
    application = Application.start()
    application.register('creative-history-undo', CreativeHistoryUndoController)
    await Promise.resolve()
  })

  afterEach(() => {
    application.stop()
    window.removeEventListener('collavre:creative-drop-complete', treeRefresh)
    jest.useRealTimers()
    document.body.innerHTML = ''
  })

  test('dismisses itself after thirty seconds', () => {
    expect(treeRefresh).toHaveBeenCalledTimes(1)
    jest.advanceTimersByTime(30000)

    expect(document.querySelector('aside')).toBeNull()
  })

  test('dismisses immediately and clears its timer', async () => {
    const clearTimeout = jest.spyOn(window, 'clearTimeout')

    document.querySelector('button').click()
    await Promise.resolve()

    expect(document.querySelector('aside')).toBeNull()
    expect(clearTimeout).toHaveBeenCalled()
  })
})
