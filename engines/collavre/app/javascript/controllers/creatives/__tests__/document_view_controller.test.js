/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import DocumentViewController from '../document_view_controller'

const flush = () => new Promise(resolve => setTimeout(resolve, 0))

let application

function mount({ active = false, withTargets = true } = {}) {
  const root = document.createElement('div')
  root.dataset.controller = 'creatives--document-view'
  root.setAttribute('data-creatives--document-view-active-value', String(active))
  if (withTargets) {
    root.innerHTML = `
      <button data-creatives--document-view-target="toggle" data-action="click->creatives--document-view#toggle"></button>
      <div id="creatives" data-creatives--document-view-target="tree">
        <creative-tree-row></creative-tree-row>
        <creative-tree-row class="plain"></creative-tree-row>
      </div>`
    root.querySelector('creative-tree-row').requestUpdate = jest.fn()
  }
  document.body.appendChild(root)
  return root
}

beforeEach(() => {
  application = Application.start()
  application.register('creatives--document-view', DocumentViewController)
  window.history.replaceState({ turbo: 1 }, '', '/creatives?id=3')
})

afterEach(async () => {
  application.stop()
  document.body.innerHTML = ''
  await flush()
})

test('toggling switches the tree between views, re-renders rows and keeps the view in the URL', async () => {
  const root = mount()
  await flush()
  const button = root.querySelector('button')
  const tree = root.querySelector('#creatives')
  const row = root.querySelector('creative-tree-row')

  expect(root.classList.contains('creative-document-view')).toBe(false)
  expect(button.getAttribute('aria-pressed')).toBe('false')
  expect(tree.hasAttribute('data-view-mode')).toBe(false)

  button.click()
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(true)
  expect(button.getAttribute('aria-pressed')).toBe('true')
  expect(tree.dataset.viewMode).toBe('document')
  expect(tree.hasAttribute('data-dnd-disabled')).toBe(true)
  expect(row.requestUpdate).toHaveBeenCalled()
  expect(window.location.search).toBe('?id=3&view=document')
  expect(window.history.state).toEqual({ turbo: 1 })

  button.click()
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(false)
  expect(button.getAttribute('aria-pressed')).toBe('false')
  expect(tree.hasAttribute('data-view-mode')).toBe(false)
  expect(tree.hasAttribute('data-dnd-disabled')).toBe(false)
  expect(window.location.search).toBe('?id=3')
})

test('starts in document view when the server rendered it active', async () => {
  const root = mount({ active: true })
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(true)
  expect(root.querySelector('button').getAttribute('aria-pressed')).toBe('true')
  expect(root.querySelector('#creatives').dataset.viewMode).toBe('document')
})

test('tolerates a page without the toggle or the tree', async () => {
  const root = mount({ active: true, withTargets: false })
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(true)
})
