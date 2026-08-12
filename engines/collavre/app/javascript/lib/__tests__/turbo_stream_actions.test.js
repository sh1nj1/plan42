/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

const fakeTurbo = { StreamActions: {} }

jest.unstable_mockModule('@hotwired/turbo-rails', () => ({ Turbo: fakeTurbo }))
jest.unstable_mockModule('../../creatives/tree_renderer', () => ({
  createRow: jest.fn(),
  applyRowProperties: jest.fn(),
  replaceProgressControl: jest.fn((_html, controlHtml) => controlHtml),
  updateProgressHtml: jest.fn((html, progress) => progress === 1
    ? html.replace('class="progress-toggle-checkbox"', 'class="progress-toggle-checkbox" checked="checked"')
      .replace('data-current-progress="0"', 'data-current-progress="1"')
      .replace('data-new-progress="1"', 'data-new-progress="0"')
      .replace('title="Mark complete"', 'title="Mark incomplete"')
    : html),
}))

await import('../turbo_stream_actions')
const { createRow } = await import('../../creatives/tree_renderer')
const { updateProgressForRow } = await import('../turbo_stream_actions')

const EMPTY_HTML = '<div data-creatives-empty-state=""><p>No sub-creatives found.</p></div>'

// Mirrors creatives/index.html.erb: title row above the tree container with the
// server-rendered placeholder inside it.
function renderEmptyTreeForParent(parentId) {
  document.body.innerHTML = `
    <creative-tree-row is-title creative-id="${parentId}"></creative-tree-row>
    <div id="creatives">${EMPTY_HTML}</div>
  `
  createRow.mockImplementation((creative) => {
    const row = document.createElement('creative-tree-row')
    row.setAttribute('creative-id', String(creative.id))
    row.setAttribute('parent-id', String(creative.parent_id))
    return row
  })
  return document.getElementById('creatives')
}

function dispatchCreativeTreeStream(payload) {
  fakeTurbo.StreamActions.refresh_creative_tree.call({
    getAttribute: (name) => name === 'data' ? JSON.stringify(payload) : null,
  })
}

afterEach(() => {
  document.body.innerHTML = ''
  jest.restoreAllMocks()
})

test('remote destroyed streams notify chat even when no tree row is visible', () => {
  const destroyedEvents = []
  const invalidatedEvents = []
  document.addEventListener('creative-destroyed', (event) => destroyedEvents.push(event.detail), { once: true })
  document.addEventListener('workspace-tree:invalidate', (event) => invalidatedEvents.push(event), { once: true })

  dispatchCreativeTreeStream({
    action: 'destroyed',
    creative: { id: 123, linked_id: 456, parent_id: 42 },
  })

  expect(destroyedEvents).toEqual([{ creativeIds: ['456', '123'] }])
  expect(invalidatedEvents).toHaveLength(1)
})

test('remote destroyed streams deduplicate identical effective and origin IDs', () => {
  const listener = jest.fn()
  document.addEventListener('creative-destroyed', listener, { once: true })

  dispatchCreativeTreeStream({
    action: 'destroyed',
    creative: { id: 123 },
  })

  expect(listener).toHaveBeenCalledWith(expect.objectContaining({
    detail: { creativeIds: ['123'] },
  }))
})

test('remote created streams clear the empty-state placeholder', () => {
  const container = renderEmptyTreeForParent(42)

  dispatchCreativeTreeStream({
    action: 'created',
    creative: { id: 7, parent_id: 42, level: 2, sequence: 0 },
  })

  expect(container.querySelector('creative-tree-row[creative-id="7"]')).not.toBeNull()
  expect(container.querySelector('[data-creatives-empty-state]').hidden).toBe(true)
})

test('remote destroyed streams restore the empty-state placeholder for the last row', () => {
  const container = renderEmptyTreeForParent(42)
  dispatchCreativeTreeStream({
    action: 'created',
    creative: { id: 7, parent_id: 42, level: 2, sequence: 0 },
  })

  dispatchCreativeTreeStream({
    action: 'destroyed',
    creative: { id: 7, parent_id: 42 },
  })

  expect(container.querySelector('creative-tree-row')).toBeNull()
  expect(container.querySelector('[data-creatives-empty-state]').hidden).toBe(false)
})

test('remote destroyed streams keep the placeholder hidden while rows remain', () => {
  const container = renderEmptyTreeForParent(42)
  dispatchCreativeTreeStream({
    action: 'created',
    creative: { id: 7, parent_id: 42, level: 2, sequence: 0 },
  })
  dispatchCreativeTreeStream({
    action: 'created',
    creative: { id: 8, parent_id: 42, level: 2, sequence: 1 },
  })

  dispatchCreativeTreeStream({
    action: 'destroyed',
    creative: { id: 7, parent_id: 42 },
  })

  expect(container.querySelector('creative-tree-row[creative-id="8"]')).not.toBeNull()
  expect(container.querySelector('[data-creatives-empty-state]').hidden).toBe(true)
})

test('remote progress updates keep checkbox controls actionable', () => {
  const row = {
    dataset: {},
    progressHtml: '<span class="progress-toggle-wrap" data-progress-toggle="true" data-current-progress="0" data-new-progress="1" data-mark-complete="Mark complete" data-mark-incomplete="Mark incomplete" title="Mark complete"><input type="checkbox" class="progress-toggle-checkbox"></span>',
  }

  updateProgressForRow(row, 1, '100%')

  expect(row.progressHtml).toContain('checked="checked"')
  expect(row.progressHtml).toContain('data-current-progress="1"')
  expect(row.progressHtml).toContain('data-new-progress="0"')
  expect(row.progressHtml).toContain('title="Mark incomplete"')
})

test('remote child creation changes the parent checkbox into its rollup control', () => {
  document.body.innerHTML = '<div id="creatives"><creative-tree-row creative-id="42"></creative-tree-row></div>'
  const parent = document.querySelector('creative-tree-row[creative-id="42"]')
  parent.progressHtml = '<span data-progress-toggle="true"><input class="progress-toggle-checkbox"></span>'
  parent.dataset.progressHtml = parent.progressHtml

  dispatchCreativeTreeStream({
    action: 'created',
    creative: {
      id: 7,
      parent_id: 42,
      level: 2,
      sequence: 0,
      ancestors: [{ id: 42, progress: 0.5, progress_html: '<span class="creative-progress-incomplete">50%</span>' }],
    },
  })

  expect(parent.hasChildren).toBe(true)
  expect(parent.progressHtml).toBe('<span class="creative-progress-incomplete">50%</span>')
})

test('remote child deletion restores the parent leaf checkbox control', () => {
  document.body.innerHTML = `
    <div id="creatives">
      <creative-tree-row creative-id="42" has-children></creative-tree-row>
      <div id="creative-children-42"><creative-tree-row creative-id="7"></creative-tree-row></div>
    </div>
  `
  const parent = document.querySelector('creative-tree-row[creative-id="42"]')
  parent.hasChildren = true
  parent.progressHtml = '<span class="creative-progress-incomplete">0%</span>'
  parent.dataset.progressHtml = parent.progressHtml
  const checkbox = '<span data-progress-toggle="true"><input class="progress-toggle-checkbox"></span>'

  dispatchCreativeTreeStream({
    action: 'destroyed',
    creative: {
      id: 7,
      parent_id: 42,
      ancestors: [{ id: 42, progress: 0, progress_html: checkbox }],
    },
  })

  expect(parent.hasChildren).toBe(false)
  expect(parent.progressHtml).toBe(checkbox)
})
