/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import { jest } from '@jest/globals'
import WorkspaceTreeController from '../workspace_tree_controller'

describe('WorkspaceTreeController', () => {
  let application
  let controller
  let fetchMock
  let preventNavigation

  beforeEach(async () => {
    fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        creatives: [
          {
            id: 1,
            label: 'Root',
            snippet: 'Root chat',
            can_comment: true,
            url: '/creatives?id=1',
            children: [
              {
                id: 2,
                label: 'Current branch',
                snippet: 'Branch chat',
                can_comment: false,
                url: '/creatives?id=2',
                children: [],
              },
            ],
          },
        ],
      }),
    })
    global.fetch = fetchMock
    window.history.replaceState({}, '', '/creatives?id=2')
    preventNavigation = (event) => event.preventDefault()
    document.addEventListener('click', preventNavigation)
    document.body.innerHTML = `
      <section data-controller="workspace-tree"
               data-workspace-tree-url-value="/creatives.json?workspace_tree=1"
               data-workspace-tree-current-path-value="[1,2,3]"
               data-workspace-tree-loading-text-value="Loading"
               data-workspace-tree-empty-text-value="Empty"
               data-workspace-tree-error-text-value="Error">
        <button data-workspace-tree-target="panelToggle" data-action="workspace-tree#togglePanel" aria-expanded="false"></button>
        <nav data-workspace-tree-target="tree"></nav>
      </section>
      <turbo-frame id="creative-workspace-content">
        <div data-workspace-navigation-state
             data-creative-id="2"
             data-creative-snippet="Branch chat"
             data-can-comment="false"
             data-creative-path="[1,2,3]"></div>
      </turbo-frame>
    `

    application = Application.start()
    application.register('workspace-tree', WorkspaceTreeController)
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))
    const controllerElement = document.querySelector('[data-controller="workspace-tree"]')
    controller = application.getControllerForElementAndIdentifier(controllerElement, 'workspace-tree')
  })

  afterEach(() => {
    controller.disconnect()
    application.stop()
    document.removeEventListener('click', preventNavigation)
    document.body.innerHTML = ''
    delete global.fetch
  })

  test('renders the tree, expands the current path, and marks the deepest visible node', () => {
    expect(fetchMock).toHaveBeenCalledWith(
      '/creatives.json?workspace_tree=1',
      expect.objectContaining({ headers: { Accept: 'application/json' } })
    )
    expect(document.querySelector('[data-creative-id="1"] > ul').hidden).toBe(false)
    expect(document.querySelector('[data-creative-id="2"] a').classList.contains('is-current')).toBe(true)
    expect(document.querySelector('[data-creative-id="2"] a').getAttribute('aria-current')).toBe('page')
    expect(document.querySelector('[data-creative-id="2"] a').dataset.turboFrame).toBe('creative-workspace-content')
    expect(document.querySelector('[data-creative-id="2"] a').dataset.turboAction).toBe('advance')
    expect(document.querySelector('.creative-workspace-tree-branch-toggle').getAttribute('aria-label')).toBe('Root')
  })

  test('toggles branches and the medium-width panel', () => {
    const branchToggle = document.querySelector('.creative-workspace-tree-branch-toggle')
    branchToggle.click()
    expect(document.querySelector('[data-creative-id="1"] > ul').hidden).toBe(true)
    expect(branchToggle.getAttribute('aria-expanded')).toBe('false')

    const panelToggle = document.querySelector('[data-workspace-tree-target="panelToggle"]')
    panelToggle.click()
    expect(panelToggle.closest('section').classList.contains('is-open')).toBe(true)
    expect(panelToggle.getAttribute('aria-expanded')).toBe('true')

    document.querySelector('.creative-workspace-tree-link').click()
    expect(panelToggle.closest('section').classList.contains('is-open')).toBe(false)
  })

  test('keeps the mounted tree state and switches chat while the center frame navigates', () => {
    const treeRegion = document.querySelector('[data-controller="workspace-tree"]')
    const rootLink = document.querySelector('[data-creative-id="1"] > div > a')
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)

    rootLink.dispatchEvent(new MouseEvent('click', { bubbles: true, button: 0, cancelable: true }))
    window.history.replaceState({}, '', '/creatives?id=1')

    expect(rootLink.classList.contains('is-current')).toBe(true)
    expect(chatListener).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '1', button: rootLink, workspaceSync: true }),
    }))

    const frame = document.getElementById('creative-workspace-content')
    const state = frame.querySelector('[data-workspace-navigation-state]')
    state.dataset.creativeId = '1'
    state.dataset.creativePath = '[1]'
    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(document.querySelector('[data-controller="workspace-tree"]')).toBe(treeRegion)
    expect(rootLink.classList.contains('is-current')).toBe(true)
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('syncs leaf and root chat state independently of visible tree links', () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    const frame = document.getElementById('creative-workspace-content')
    const state = frame.querySelector('[data-workspace-navigation-state]')

    state.dataset.creativeId = '3'
    state.dataset.creativeSnippet = 'Leaf chat'
    state.dataset.canComment = 'true'
    state.dataset.creativePath = '[1,2,3]'
    window.history.replaceState({}, '', '/creatives?id=3')
    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(document.querySelector('[data-creative-id="2"] a').classList.contains('is-current')).toBe(true)
    expect(chatListener).toHaveBeenLastCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '3', button: state, workspaceSync: true }),
    }))

    delete state.dataset.creativeId
    state.dataset.creativePath = '[]'
    window.history.replaceState({}, '', '/creatives')
    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(document.querySelector('.creative-workspace-tree-link.is-current')).toBeNull()
    expect(chatListener).toHaveBeenLastCalledWith(expect.objectContaining({
      detail: expect.objectContaining({
        creativeId: undefined,
        button: expect.any(HTMLElement),
        workspaceSync: true,
      }),
    }))
    expect(chatListener.mock.lastCall[0].detail.button.dataset.workspaceNavigationState).toBe('true')
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('trusts the completed frame response when an inaccessible id falls back to root', () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    const frame = document.getElementById('creative-workspace-content')
    const state = frame.querySelector('[data-workspace-navigation-state]')

    delete state.dataset.creativeId
    state.dataset.creativePath = '[]'
    window.history.replaceState({}, '', '/creatives?id=999999')
    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(document.querySelector('.creative-workspace-tree-link.is-current')).toBeNull()
    expect(chatListener).toHaveBeenLastCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: undefined }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('ignores a pre-load frame render while the URL and frame state disagree', () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    const frame = document.getElementById('creative-workspace-content')
    const state = frame.querySelector('[data-workspace-navigation-state]')

    state.dataset.creativeId = '1'
    state.dataset.creativePath = '[1]'
    window.history.replaceState({}, '', '/creatives?id=2')
    frame.dispatchEvent(new CustomEvent('turbo:frame-render', { bubbles: true }))

    expect(document.querySelector('[data-creative-id="2"] a').classList.contains('is-current')).toBe(true)
    expect(chatListener).not.toHaveBeenCalled()
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('refreshes stale data while preserving explicit branch state', async () => {
    const branchToggle = document.querySelector('.creative-workspace-tree-branch-toggle')
    branchToggle.click()
    expect(branchToggle.getAttribute('aria-expanded')).toBe('false')

    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        creatives: [{
          id: 1,
          label: 'Renamed root',
          url: '/creatives?id=1',
          children: [{ id: 2, label: 'Current branch', url: '/creatives?id=2', children: [] }],
        }],
      }),
    })
    document.dispatchEvent(new CustomEvent('workspace-tree:invalidate'))
    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(document.querySelector('[data-creative-id="1"] > div > a').textContent).toBe('Renamed root')
    expect(document.querySelector('.creative-workspace-tree-branch-toggle').getAttribute('aria-expanded')).toBe('false')
  })

  test('shows the empty state', async () => {
    const controllerElement = document.querySelector('[data-controller="workspace-tree"]')
    const controller = application.getControllerForElementAndIdentifier(controllerElement, 'workspace-tree')

    controller.render([])

    expect(document.querySelector('.creative-workspace-tree-status').textContent).toBe('Empty')
  })

  test('shows the localized error state when loading fails', async () => {
    const controllerElement = document.querySelector('[data-controller="workspace-tree"]')
    const controller = application.getControllerForElementAndIdentifier(controllerElement, 'workspace-tree')
    fetchMock.mockRejectedValueOnce(new Error('offline'))
    jest.spyOn(console, 'error').mockImplementation(() => {})

    await controller.load()

    expect(document.querySelector('.creative-workspace-tree-status').textContent).toBe('Error')
    console.error.mockRestore()
  })
})
