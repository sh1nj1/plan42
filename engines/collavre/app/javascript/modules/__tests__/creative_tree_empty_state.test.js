/**
 * @jest-environment jsdom
 */
import {
  creativeTreeContainer,
  hideTreeEmptyState,
  restoreTreeEmptyState,
  PAGINATION_PENDING_ATTRIBUTE,
} from '../creative_tree_empty_state'

const EMPTY_HTML = '<div data-creatives-empty-state=""><p>No sub-creatives found.</p></div>'

const EMPTY_TEMPLATE = `<template id="creatives-empty-state-template">${EMPTY_HTML}</template>`

function renderEmptyTree() {
  document.body.innerHTML = `<div id="creatives">${EMPTY_HTML}</div>`
  return document.getElementById('creatives')
}

// The state after a client-side tree render: rows replaced the whole container,
// so the server-rendered placeholder is gone and only the template survives.
function renderRenderedTree(innerHtml = '') {
  document.body.innerHTML = `${EMPTY_TEMPLATE}<div id="creatives">${innerHtml}</div>`
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

test('restoreTreeEmptyState is a no-op when neither placeholder nor template exists', () => {
  document.body.innerHTML = '<div id="creatives"></div>'
  const container = document.getElementById('creatives')

  restoreTreeEmptyState(container)

  expect(container.innerHTML).toBe('')
})

test('restoreTreeEmptyState clones the template when the tree render wiped the container', () => {
  const container = renderRenderedTree()

  restoreTreeEmptyState(container)

  const restored = placeholder(container)
  expect(restored).not.toBeNull()
  expect(restored.hidden).toBe(false)
  expect(restored.textContent).toContain('No sub-creatives found.')
})

test('restoreTreeEmptyState does not clone the template while rows remain', () => {
  const container = renderRenderedTree('<creative-tree-row creative-id="7"></creative-tree-row>')

  restoreTreeEmptyState(container)

  expect(placeholder(container)).toBeNull()
})

test('restoreTreeEmptyState does not clone the template when a placeholder is already present', () => {
  document.body.innerHTML = `${EMPTY_TEMPLATE}<div id="creatives">${EMPTY_HTML}</div>`
  const container = document.getElementById('creatives')
  hideTreeEmptyState(container)

  restoreTreeEmptyState(container)

  expect(container.querySelectorAll('[data-creatives-empty-state]')).toHaveLength(1)
  expect(placeholder(container).hidden).toBe(false)
})

test('cloning the template leaves the template itself untouched', () => {
  const container = renderRenderedTree()

  restoreTreeEmptyState(container)
  hideTreeEmptyState(container)
  container.replaceChildren()
  restoreTreeEmptyState(container)

  // A second restore after a second wipe must still produce a visible placeholder:
  // hideTreeEmptyState() must not have mutated the template's own copy.
  expect(placeholder(container).hidden).toBe(false)
})

test('restoreTreeEmptyState is a no-op without a tree container', () => {
  document.body.innerHTML = ''
  expect(() => restoreTreeEmptyState()).not.toThrow()
  expect(() => restoreTreeEmptyState(null)).not.toThrow()
})

// Paginated "Chats" feed: an empty container is not an empty result set while the
// load-more sentinel still has pages to fetch.
test('restoreTreeEmptyState stays out of the way while more pages are queued', () => {
  const container = renderRenderedTree()
  container.setAttribute(PAGINATION_PENDING_ATTRIBUTE, 'true')

  restoreTreeEmptyState(container)

  expect(placeholder(container)).toBeNull()
})

test('restoreTreeEmptyState leaves an existing placeholder hidden while more pages are queued', () => {
  const container = renderEmptyTree()
  hideTreeEmptyState(container)
  container.setAttribute(PAGINATION_PENDING_ATTRIBUTE, 'true')

  restoreTreeEmptyState(container)

  expect(placeholder(container).hidden).toBe(true)
})

test('restoreTreeEmptyState restores once the pending-pages marker is cleared', () => {
  const container = renderRenderedTree()
  container.setAttribute(PAGINATION_PENDING_ATTRIBUTE, 'true')
  restoreTreeEmptyState(container)
  container.removeAttribute(PAGINATION_PENDING_ATTRIBUTE)

  restoreTreeEmptyState(container)

  expect(placeholder(container)).not.toBeNull()
  expect(placeholder(container).hidden).toBe(false)
})
