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
  document.body.innerHTML = `<div id="creatives">${EMPTY_HTML}</div>`
  return document.getElementById('creatives')
}

function placeholder(container) {
  return container.querySelector('[data-creatives-empty-state]')
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

test('hideTreeEmptyState hides the placeholder', () => {
  const container = renderEmptyTree()

  hideTreeEmptyState(container)

  expect(placeholder(container).hidden).toBe(true)
  expect(placeholder(container).style.display).toBe('none')
})

test('hideTreeEmptyState defaults to #creatives when no container is passed', () => {
  const container = renderEmptyTree()

  hideTreeEmptyState()

  expect(placeholder(container).hidden).toBe(true)
})

test('hideTreeEmptyState is a no-op without a tree container', () => {
  document.body.innerHTML = ''
  expect(() => hideTreeEmptyState()).not.toThrow()
  expect(() => hideTreeEmptyState(null)).not.toThrow()
})

test('restoreTreeEmptyState shows the placeholder again once the tree is empty', () => {
  const container = renderEmptyTree()
  hideTreeEmptyState(container)

  restoreTreeEmptyState(container)

  expect(placeholder(container).hidden).toBe(false)
  expect(placeholder(container).style.display).toBe('')
  expect(placeholder(container).textContent).toContain('No sub-creatives found.')
})

test('restoreTreeEmptyState keeps the placeholder hidden while rows remain', () => {
  const container = renderEmptyTree()
  hideTreeEmptyState(container)
  container.insertAdjacentHTML('beforeend', '<creative-tree-row creative-id="7"></creative-tree-row>')

  restoreTreeEmptyState(container)

  expect(placeholder(container).hidden).toBe(true)
})

test('restoreTreeEmptyState does not duplicate the placeholder', () => {
  const container = renderEmptyTree()

  restoreTreeEmptyState(container)

  expect(container.querySelectorAll('[data-creatives-empty-state]')).toHaveLength(1)
})

test('restoreTreeEmptyState is a no-op when the tree has no placeholder', () => {
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
