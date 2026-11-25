/** @jest-environment jsdom */
import { jest } from '@jest/globals'

const invalidateCreativeTree = jest.fn()
jest.unstable_mockModule('../../../lib/creative_tree_invalidation', () => ({ invalidateCreativeTree }))
const fetch = jest.fn()
const alertDialog = jest.fn()
jest.unstable_mockModule('../../../lib/api/csrf_fetch', () => ({ default: fetch }))
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog }))
const { createCreativeFileDrop, fileDragKind, uploadDroppedFiles } = await import('../file_drop')

let registry
let tree
const file = new File(['notes'], 'notes.txt', { type: 'text/plain' })
const flush = () => new Promise(resolve => setTimeout(resolve, 0))
function drag(type, y, transfer = { types: ['Files'], files: [file] }) {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.assign(event, { clientY: y, dataTransfer: transfer })
  tree.dispatchEvent(event)
  return event
}

beforeEach(() => {
  jest.clearAllMocks()
  jest.spyOn(console, 'error').mockImplementation(() => {})
  fetch.mockResolvedValue({ ok: true, json: async () => ({ id: 2 }) })
  document.body.innerHTML = '<creative-tree-row creative-id="42"><div class="creative-tree" draggable="true"></div></creative-tree-row>'
  tree = document.querySelector('.creative-tree')
  tree.getBoundingClientRect = () => ({ top: 0, height: 100 })
  registry = createCreativeFileDrop({ failureMessage: '첨부 실패' })
})
afterEach(() => { registry.destroy(); jest.restoreAllMocks() })

test.each([[5, 'up', 'top'], [50, 'child', 'child'], [95, 'down', 'bottom']])(
  'previews and uploads position %s as %s', async (y, direction, highlight) => {
    const transfer = { types: ['Files'], files: [file, file] }
    expect(drag('dragover', y, transfer).defaultPrevented).toBe(true)
    expect(transfer.dropEffect).toBe('copy')
    expect(tree.classList.contains(`drag-over-${highlight}`)).toBe(true)
    expect(tree.classList.contains('child-drop-indicator-active')).toBe(direction === 'child')
    expect(drag('drop', y, transfer).defaultPrevented).toBe(true)
    await flush()
    expect(invalidateCreativeTree).toHaveBeenCalledTimes(1)
    expect(fetch).toHaveBeenCalledTimes(1)
    const [url, options] = fetch.mock.calls[0]
    expect(url).toBe('/creatives/42/file_drops')
    expect(options.body.get('direction')).toBe(direction)
    expect(options.body.getAll('files[]')).toHaveLength(2)
    expect(tree.classList.contains('drag-over')).toBe(false)
  },
)

test('keeps the previewed position across drop hysteresis', async () => {
  drag('dragover', 5)
  drag('drop', 50)
  await flush()
  expect(fetch.mock.calls[0][1].body.get('direction')).toBe('up')
})

test('leaving or destroying the zone cleans up the preview', () => {
  drag('dragover', 50)
  drag('dragleave', 50)
  expect(tree.classList.contains('drag-over')).toBe(false)
  drag('dragover', 50)
  registry.destroy()
  expect(tree.classList.contains('drag-over')).toBe(false)
})

test('ignores empty files, editing rows and other drag payloads', async () => {
  drag('drop', 50, { types: ['Files'] })
  drag('drop', 50, { types: ['Files'], files: [] })
  tree.draggable = false
  drag('drop', 50)
  tree.draggable = true
  drag('drop', 50, { types: ['application/x-collavre-creative', 'Files'], files: [file] })
  await flush()
  expect(fetch).not.toHaveBeenCalled()
  expect(fileDragKind()).toBeNull()
  expect(fileDragKind({ types: ['text/plain'] })).toBeNull()
})

test.each(['http', 'redirect', 'html', 'network'])('reports %s failure with translated text', async kind => {
  if (kind === 'network') fetch.mockRejectedValue(new Error('offline'))
  else fetch.mockResolvedValue({ ok: kind !== 'http', redirected: kind === 'redirect',
    json: async () => { throw new Error('invalid json') } })
  drag('drop', 50)
  await flush()
  expect(invalidateCreativeTree).not.toHaveBeenCalled()
  expect(alertDialog).toHaveBeenCalledWith('첨부 실패')
})

test('does not upload when the target row has no ID', async () => {
  tree.remove()
  await uploadDroppedFiles({ el: tree, hit: 'child', payload: { files: [file] } }, 'failure')
  document.body.innerHTML = '<creative-tree-row><div class="creative-tree"></div></creative-tree-row>'
  tree = document.querySelector('.creative-tree')
  await uploadDroppedFiles({ el: tree, hit: 'child', payload: { files: [file] } }, 'failure')
  expect(fetch).not.toHaveBeenCalled()
})
