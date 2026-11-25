/** @jest-environment jsdom */
import { jest } from '@jest/globals'

const get = jest.fn()
const syncProgressHtmlFromDom = jest.fn()
const replaceProgressControl = jest.fn((current, control) => `${current}+${control}`)
jest.unstable_mockModule('../../lib/api/creatives', () => ({ default: { get } }))
jest.unstable_mockModule('../tree_renderer', () => ({ replaceProgressControl, syncProgressHtmlFromDom }))
const listIsFiltered = jest.fn()
jest.unstable_mockModule('../tree_reload_events', () => ({ listIsFiltered }))
const { refreshMovedBranchProgress, refreshProgressAbove } = await import('../row_progress')

const row = (id) => document.querySelector(`creative-tree-row[creative-id="${id}"]`)

beforeEach(() => {
  jest.clearAllMocks()
  listIsFiltered.mockReturnValue(false)
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

// A row with no control yet takes the server's; one that has it swaps it in,
// after anything typed into the row since it was drawn is read back.
test('a refetched row keeps its own controls around the new progress', async () => {
  row(4).progressHtml = '<old four>'
  get.mockImplementation((id) => Promise.resolve(id === '1' ? { progress: 0.25 } : { progress: 0.5, progress_html: '<four>' }))

  await refreshMovedBranchProgress('4', null)

  expect(shown(4)).toEqual(['0.5', '<old four>+<four>', '<old four>+<four>'])
  expect(shown(1)).toEqual(['0.25', undefined, undefined])
  expect(syncProgressHtmlFromDom.mock.calls).toEqual([[row(4)]])
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
  await refreshMovedBranchProgress('2', '2x', jest.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({}))

  await expect(refreshMovedBranchProgress('4', null)).resolves.toEqual([undefined, undefined])
  expect(shown(4)).toEqual([undefined, undefined, undefined])
})

test('a created row refetches the rows above its parent, which the editor refetches itself', async () => {
  get.mockImplementation((id) => Promise.resolve({ progress: 0.5, progress_html: `<${id}>` }))

  await refreshProgressAbove('3')
  await refreshProgressAbove('1')
  await refreshProgressAbove('')
  await refreshProgressAbove('77')

  expect(get.mock.calls.map(([id]) => id)).toEqual(['2', '1'])
  expect(shown(2)).toEqual(['0.5', '<2>', '<2>'])
})

// The progress a filtered list shows is the filter's own; the list refetches
// itself instead, and unfiltered values must not be painted over it meanwhile.
test('a filtered list is left for its own refetch', async () => {
  listIsFiltered.mockReturnValue(true)

  await refreshMovedBranchProgress('2', '4')
  await refreshProgressAbove('3')

  expect(get).not.toHaveBeenCalled()
  expect(shown(2)).toEqual([undefined, undefined, undefined])
})
