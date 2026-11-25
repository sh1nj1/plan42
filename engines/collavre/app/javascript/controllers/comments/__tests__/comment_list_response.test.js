/** @jest-environment jsdom */
import { syncCommentListProgress } from '../comment_list_response'
import { observeCreativeProgress } from '../popup_creative_progress'

test('refreshes server progress whenever the tree does not provide it', () => {
  const element = document.createElement('div')
  element.dataset.creativeId = '42'
  const bar = element.appendChild(document.createElement('creative-header-progress'))
  const popup = { hasProgressTarget: true, progressTarget: bar }
  const controller = { creativeId: '42', element }
  const applyResponse = value => {
    syncCommentListProgress(controller, { headers: new Map([['X-Creative-Progress', value]]) }, { creativeId: '42' })
  }

  observeCreativeProgress(popup, null, '42')
  applyResponse('0')
  expect(bar.value).toBe(0)
  applyResponse('0.4')
  expect(bar.value).toBe(0.4)

  const row = document.createElement('div')
  row.dataset.progressValue = '0.8'
  observeCreativeProgress(popup, row, '42')
  applyResponse('0.5')
  expect(bar.value).toBe(0.8)

  observeCreativeProgress(popup, null, '42')
  applyResponse('0.6')
  expect(bar.value).toBe(0.6)
})
