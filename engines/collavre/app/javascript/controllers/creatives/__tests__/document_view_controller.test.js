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

const viewCookie = () => document.cookie.split('; ').find(cookie => cookie.startsWith('creative_view=')) || null

beforeEach(() => {
  document.cookie = 'creative_view=; max-age=0; path=/'
  application = Application.start()
  application.register('creatives--document-view', DocumentViewController)
  window.history.replaceState({ turbo: 1 }, '', '/creatives?id=3')
})

afterEach(async () => {
  application.stop()
  document.body.innerHTML = ''
  await flush()
})

test('toggling switches the tree between views, re-renders rows and remembers the view in a cookie', async () => {
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
  expect(viewCookie()).toBe('creative_view=document')
  expect(window.location.search).toBe('?id=3')

  button.click()
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(false)
  expect(button.getAttribute('aria-pressed')).toBe('false')
  expect(tree.hasAttribute('data-view-mode')).toBe(false)
  expect(tree.hasAttribute('data-dnd-disabled')).toBe(false)
  expect(viewCookie()).toBeNull()
})

test('starts in document view when the server rendered it active', async () => {
  document.cookie = 'creative_view=document; path=/'
  const root = mount({ active: true })
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(true)
  expect(root.querySelector('button').getAttribute('aria-pressed')).toBe('true')
  expect(root.querySelector('#creatives').dataset.viewMode).toBe('document')
})

test('a page restored from the cache follows the remembered view', async () => {
  document.cookie = 'other=1; path=/'
  document.cookie = 'creative_view=document; path=/'
  const stale = mount({ active: false })
  await flush()

  expect(stale.classList.contains('creative-document-view')).toBe(true)
  expect(stale.querySelector('#creatives').dataset.viewMode).toBe('document')

  stale.remove()
  document.cookie = 'creative_view=; max-age=0; path=/'
  const staleDocument = mount({ active: true })
  await flush()

  expect(staleDocument.classList.contains('creative-document-view')).toBe(false)
  expect(staleDocument.querySelector('button').getAttribute('aria-pressed')).toBe('false')
})

test('a view link is adopted as the remembered view and dropped from the URL', async () => {
  window.history.replaceState({ turbo: 1 }, '', '/creatives?id=3&view=document')
  const root = mount({ active: true })
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(true)
  expect(viewCookie()).toBe('creative_view=document')
  expect(window.location.search).toBe('?id=3')
  expect(window.history.state).toEqual({ turbo: 1 })
})

test('a link to another view leaves document view', async () => {
  document.cookie = 'creative_view=document; path=/'
  window.history.replaceState({}, '', '/creatives?view=tree')
  const root = mount({ active: false })
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(false)
  expect(viewCookie()).toBeNull()
  expect(window.location.search).toBe('')
})

test('tolerates a page without the toggle or the tree', async () => {
  document.cookie = 'creative_view=document; path=/'
  const root = mount({ active: true, withTargets: false })
  await flush()

  expect(root.classList.contains('creative-document-view')).toBe(true)
})
