/**
 * @jest-environment jsdom
 */
import {
  creativeTreeContainer,
  hideTreeEmptyState,
  restoreTreeEmptyState,
} from '../creative_tree_empty_state'

const EMPTY_HTML = '<div data-creatives-empty-state=""><p>No sub-creatives found.</p></div>'

function renderEmptyTree() {
  document.body.innerHTML = `
    <div id="creatives" data-creatives--tree-empty-html-value='${EMPTY_HTML}'>
      ${EMPTY_HTML}
    </div>
  `
  return document.getElementById('creatives')
}

afterEach(() => {
  document.body.innerHTML = ''
})

test('creativeTreeContainer resolves the tree container', () => {
  const container = renderEmptyTree()
  expect(creativeTreeContainer()).toBe(container)
})

test('creativeTreeContainer returns null when the tree is not on the page', () => {
  document.body.innerHTML = ''
  expect(creativeTreeContainer()).toBeNull()
})

test('hideTreeEmptyState removes the placeholder', () => {
  const container = renderEmptyTree()
  hideTreeEmptyState(container)
  expect(container.querySelector('[data-creatives-empty-state]')).toBeNull()
})

test('hideTreeEmptyState defaults to #creatives when no container is passed', () => {
  const container = renderEmptyTree()
  hideTreeEmptyState()
  expect(container.querySelector('[data-creatives-empty-state]')).toBeNull()
})

test('hideTreeEmptyState is a no-op without a tree container', () => {
  document.body.innerHTML = ''
  expect(() => hideTreeEmptyState()).not.toThrow()
  expect(() => hideTreeEmptyState(null)).not.toThrow()
})

test('restoreTreeEmptyState re-renders the placeholder once the tree is empty', () => {
  const container = renderEmptyTree()
  hideTreeEmptyState(container)

  restoreTreeEmptyState(container)

  const placeholder = container.querySelector('[data-creatives-empty-state]')
  expect(placeholder).not.toBeNull()
  expect(placeholder.textContent).toContain('No sub-creatives found.')
})

test('restoreTreeEmptyState does nothing while rows remain', () => {
  const container = renderEmptyTree()
  hideTreeEmptyState(container)
  container.innerHTML = '<creative-tree-row creative-id="7"></creative-tree-row>'

  restoreTreeEmptyState(container)

  expect(container.querySelector('[data-creatives-empty-state]')).toBeNull()
})

test('restoreTreeEmptyState does not duplicate an existing placeholder', () => {
  const container = renderEmptyTree()

  restoreTreeEmptyState(container)

  expect(container.querySelectorAll('[data-creatives-empty-state]')).toHaveLength(1)
})

test('restoreTreeEmptyState is a no-op when no cached markup exists', () => {
  document.body.innerHTML = '<div id="creatives"></div>'
  const container = document.getElementById('creatives')

  restoreTreeEmptyState(container)

  expect(container.innerHTML).toBe('')
})

test('restoreTreeEmptyState is a no-op without a tree container', () => {
  document.body.innerHTML = ''
  expect(() => restoreTreeEmptyState()).not.toThrow()
  expect(() => restoreTreeEmptyState(null)).not.toThrow()
})
