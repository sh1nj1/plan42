/** @jest-environment jsdom */
import { jest } from '@jest/globals'

const get = jest.fn()
const syncProgressHtmlFromDom = jest.fn()
const replaceProgressControl = jest.fn((current, control) => `${current}+${control}`)
jest.unstable_mockModule('../../lib/api/creatives', () => ({ default: { get } }))
jest.unstable_mockModule('../tree_renderer', () => ({ replaceProgressControl, syncProgressHtmlFromDom }))
const { applySavedProgress, refreshMovedBranchProgress } = await import('../row_progress')

const row = (id) => document.querySelector(`creative-tree-row[creative-id="${id}"]`)

beforeEach(() => {
  jest.clearAllMocks()
  // 1 > 2 > 3 and 1 > 4; 5 names a parent that is not on screen.
  document.body.innerHTML = `
    <creative-tree-row creative-id="1"></creative-tree-row>
    <creative-tree-row creative-id="2" parent-id="1"></creative-tree-row>
    <creative-tree-row creative-id="3" parent-id="2"></creative-tree-row>
    <creative-tree-row creative-id="4" parent-id="1"></creative-tree-row>
    <creative-tree-row creative-id="6" parent-id="5"></creative-tree-row>
  `
})

const shown = (id) => [row(id).dataset.progressValue, row(id).progressHtml, row(id).dataset.progressHtml]

test('a save response paints the saved row and every ancestor on screen', () => {
  row(2).progressHtml = '<old two>'

  applySavedProgress(row(3), {
    progress: 1,
    progress_html: '<own>',
    ancestors: [
      { id: 2, progress: 0.5, progress_html: '<two>' },
      { id: 1, progress: 0.25 },
      { id: 99, progress: 0.75, progress_html: '<off screen>' },
    ],
  })

  // A row with no control yet takes the server's; one that has it swaps it in.
  expect(shown(3)).toEqual(['1', '<own>', '<own>'])
  expect(shown(2)).toEqual(['0.5', '<old two>+<two>', '<old two>+<two>'])
  expect(shown(1)).toEqual(['0.25', undefined, undefined])
  expect(syncProgressHtmlFromDom.mock.calls).toEqual([[row(3)], [row(2)]])
})

test('a response without progress, or a row that is gone, paints nothing', () => {
  applySavedProgress(row(3), undefined)
  applySavedProgress(row(3), { ancestors: 'none' })
  applySavedProgress(null, { progress: 1, progress_html: '<own>' })

  expect(shown(3)).toEqual([undefined, undefined, undefined])
  expect(syncProgressHtmlFromDom).not.toHaveBeenCalled()
})

test('a move between parents refetches each row above either parent once', async () => {
  get.mockImplementation((id) => Promise.resolve({ progress: Number(id) / 10, progress_html: `<${id}>` }))

  await refreshMovedBranchProgress('2', '4')

  expect(get.mock.calls.map(([id]) => id)).toEqual(['2', '1', '4'])
  expect([2, 1, 4].map((id) => shown(id))).toEqual([
    ['0.2', '<2>', '<2>'],
    ['0.1', '<1>', '<1>'],
    ['0.4', '<4>', '<4>'],
  ])
})

test('a move to or from the top level, or under a parent that is off screen, refetches what is there', async () => {
  const fetchCreative = jest.fn().mockResolvedValue({ progress: 0 })

  await refreshMovedBranchProgress(null, '2', fetchCreative)
  await refreshMovedBranchProgress('6', '', fetchCreative)
  await refreshMovedBranchProgress('5', '77', fetchCreative)

  // Row 6's parent is not rendered, so the walk ends at row 6.
  expect(fetchCreative.mock.calls.map(([id]) => id)).toEqual(['2', '1', '6'])
  expect(get).not.toHaveBeenCalled()
})

test('a move within one parent changes no roll-up and fetches nothing', async () => {
  await refreshMovedBranchProgress('2', 2)
  await refreshMovedBranchProgress(null, '')

  expect(get).not.toHaveBeenCalled()
})

test('a refetch that rejects or throws leaves the row as it was', async () => {
  get.mockRejectedValueOnce(new Error('offline')).mockImplementationOnce(() => { throw new Error('no transport') })

  await expect(refreshMovedBranchProgress('4', null)).resolves.toEqual([undefined, undefined])
  expect(shown(4)).toEqual([undefined, undefined, undefined])
})
