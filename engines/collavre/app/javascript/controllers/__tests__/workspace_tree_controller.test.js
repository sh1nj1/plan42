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
    const [requestUrl, requestOptions] = fetchMock.mock.calls[0]
    expect(new URL(requestUrl, window.location.origin).searchParams.getAll('expand[]')).toEqual(['1', '2', '3'])
    expect(requestOptions).toEqual(expect.objectContaining({ headers: { Accept: 'application/json' } }))
    expect(document.querySelector('[data-creative-id="1"] > ul')).not.toBeNull()
    expect(document.querySelector('[data-creative-id="2"] a').classList.contains('is-current')).toBe(true)
    expect(document.querySelector('[data-creative-id="2"] a').getAttribute('aria-current')).toBe('page')
    expect(document.querySelector('[data-creative-id="2"] a').dataset.turboFrame).toBe('creative-workspace-content')
    expect(document.querySelector('[data-creative-id="2"] a').dataset.turboAction).toBe('advance')
    expect(document.querySelector('.creative-workspace-tree-branch-toggle').getAttribute('aria-label')).toBe('Root')
  })

  test('lazily reloads toggled branches and restores focus and scroll', async () => {
    let branchToggle = document.querySelector('.creative-workspace-tree-branch-toggle')
    controller.treeTarget.scrollTop = 24
    branchToggle.click()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(document.querySelector('[data-creative-id="1"] > ul')).toBeNull()
    branchToggle = document.querySelector('.creative-workspace-tree-branch-toggle')
    expect(branchToggle.getAttribute('aria-expanded')).toBe('false')
    expect(document.activeElement).toBe(branchToggle)
    expect(controller.treeTarget.scrollTop).toBe(24)
    let requestUrl = fetchMock.mock.calls[1][0]
    expect(new URL(requestUrl, window.location.origin).searchParams.getAll('expand[]')).toEqual(['2', '3'])

    branchToggle.click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    branchToggle = document.querySelector('.creative-workspace-tree-branch-toggle')
    expect(document.querySelector('[data-creative-id="1"] > ul')).not.toBeNull()
    expect(branchToggle.getAttribute('aria-expanded')).toBe('true')
    expect(document.activeElement).toBe(branchToggle)
    requestUrl = fetchMock.mock.calls[2][0]
    expect(new URL(requestUrl, window.location.origin).searchParams.getAll('expand[]')).toEqual(['2', '3', '1'])

    const panelToggle = document.querySelector('[data-workspace-tree-target="panelToggle"]')
    panelToggle.click()
    expect(panelToggle.closest('section').classList.contains('is-open')).toBe(true)
    expect(panelToggle.getAttribute('aria-expanded')).toBe('true')

    document.querySelector('.creative-workspace-tree-link').click()
    expect(panelToggle.closest('section').classList.contains('is-open')).toBe(false)
  })

  test('preserves link focus across background tree refreshes', async () => {
    let rootLink = document.querySelector('[data-creative-id="1"] > div > a')
    rootLink.focus()

    await controller.load({ showLoading: false, syncChat: false, preserveView: true })

    rootLink = document.querySelector('[data-creative-id="1"] > div > a')
    expect(document.activeElement).toBe(rootLink)

    let leafLink = document.querySelector('[data-creative-id="2"] a')
    leafLink.focus()

    await controller.load({ showLoading: false, syncChat: false, preserveView: true })

    leafLink = document.querySelector('[data-creative-id="2"] a')
    expect(document.activeElement).toBe(leafLink)
  })

  test('keeps the rendered branch state when a lazy reload fails', async () => {
    fetchMock.mockRejectedValueOnce(new Error('offline'))
    jest.spyOn(console, 'error').mockImplementation(() => {})
    const branchToggle = document.querySelector('.creative-workspace-tree-branch-toggle')

    branchToggle.click()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(controller.expandedCreativeIds.has('1')).toBe(true)
    expect(document.querySelector('[data-creative-id="1"] > ul')).not.toBeNull()
    expect(branchToggle.disabled).toBe(false)
    console.error.mockRestore()
  })

  test('ignores a stale non-abort failure after a newer tree request commits', async () => {
    let rejectToggleRequest
    fetchMock.mockReturnValueOnce(new Promise((_resolve, reject) => {
      rejectToggleRequest = reject
    }))
    const branchToggle = document.querySelector('.creative-workspace-tree-branch-toggle')
    branchToggle.click()
    await new Promise((resolve) => setTimeout(resolve, 0))

    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ creatives: [{ id: 1, label: 'Root', url: '/creatives?id=1', has_children: true, children: [] }] }),
    })
    await controller.load({ showLoading: false, syncChat: false })
    rejectToggleRequest(new Error('stale offline failure'))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(controller.expandedCreativeIds.has('1')).toBe(false)
    expect(controller.committedExpandedCreativeIds.has('1')).toBe(false)
    expect(document.querySelector('[data-creative-id="1"] > ul')).toBeNull()
  })

  test('reverts an aborted toggle when the latest owner request fails', async () => {
    let rejectToggleRequest
    fetchMock.mockReturnValueOnce(new Promise((_resolve, reject) => {
      rejectToggleRequest = reject
    }))
    jest.spyOn(console, 'error').mockImplementation(() => {})
    document.querySelector('.creative-workspace-tree-branch-toggle').click()
    await new Promise((resolve) => setTimeout(resolve, 0))

    fetchMock.mockRejectedValueOnce(new Error('refresh failed'))
    await controller.load({ showLoading: false, syncChat: false })
    rejectToggleRequest(new DOMException('Aborted', 'AbortError'))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(controller.expandedCreativeIds.has('1')).toBe(true)
    expect(controller.committedExpandedCreativeIds.has('1')).toBe(true)
    expect(document.querySelector('[data-creative-id="1"] > ul')).not.toBeNull()
    console.error.mockRestore()
  })

  test('bounds the expanded branch request state', () => {
    controller.currentPathValue = []
    controller.expandedCreativeIds.clear()

    controller.addExpandedPath(Array.from({ length: 101 }, (_value, index) => index + 1000))

    expect(controller.expandedCreativeIds.size).toBe(100)
    expect(controller.expandedCreativeIds.has('1000')).toBe(false)
    expect(controller.expandedCreativeIds.has('1100')).toBe(true)
    expect(new URL(controller.workspaceTreeUrl(), window.location.origin).searchParams.getAll('expand[]')).toHaveLength(100)
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

  test('forwards comment targets only from authoritative frame loads', () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    const frame = document.getElementById('creative-workspace-content')
    window.history.replaceState({}, '', '/creatives/2/comments/456')

    frame.dispatchEvent(new CustomEvent('turbo:frame-render', { bubbles: true }))
    expect(chatListener).toHaveBeenLastCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2', highlightId: undefined }),
    }))

    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))
    expect(chatListener).toHaveBeenLastCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2', highlightId: '456' }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('extracts query, path, and hash comment targets from workspace URLs', () => {
    window.history.replaceState({}, '', '/creatives?id=2&comment_id=456')
    expect(controller.commentIdFromLocation()).toBe('456')

    window.history.replaceState({}, '', '/creatives?id=2&highlight_comment_id=567')
    expect(controller.commentIdFromLocation()).toBe('567')

    window.history.replaceState({}, '', '/creatives/2/comments/678')
    expect(controller.commentIdFromLocation()).toBe('678')

    window.history.replaceState({}, '', '/creatives?id=2#comment_789')
    expect(controller.commentIdFromLocation()).toBe('789')

    window.history.replaceState({}, '', '/creatives?id=2')
    expect(controller.commentIdFromLocation()).toBeUndefined()
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
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(document.querySelector('.creative-workspace-tree-branch-toggle').getAttribute('aria-expanded')).toBe('false')

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

    expect(fetchMock).toHaveBeenCalledTimes(3)
    expect(document.querySelector('[data-creative-id="1"] > div > a').textContent).toBe('Renamed root')
    expect(document.querySelector('.creative-workspace-tree-branch-toggle').getAttribute('aria-expanded')).toBe('false')
  })

  test('loads a newly navigated frame path without reopening chat', async () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        creatives: [{
          id: 1,
          label: 'Root',
          url: '/creatives?id=1',
          has_children: true,
          children: [{ id: 4, label: 'New branch', url: '/creatives?id=4', has_children: true, children: [] }],
        }],
      }),
    })
    const frame = document.getElementById('creative-workspace-content')
    const state = frame.querySelector('[data-workspace-navigation-state]')
    state.dataset.creativeId = '5'
    state.dataset.creativePath = '[1,4,5]'
    window.history.replaceState({}, '', '/creatives?id=5')

    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))
    await new Promise((resolve) => setTimeout(resolve, 0))

    const requestUrl = fetchMock.mock.calls[1][0]
    expect(new URL(requestUrl, window.location.origin).searchParams.getAll('expand[]')).toEqual(['1', '2', '3', '4', '5'])
    expect(document.querySelector('[data-creative-id="4"] a').classList.contains('is-current')).toBe(true)
    expect(chatListener).toHaveBeenCalledTimes(1)
    expect(chatListener).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '5', workspaceSync: true }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('retries an unresolved frame path on the next tree refresh', async () => {
    fetchMock.mockRejectedValueOnce(new Error('path load failed'))
    jest.spyOn(console, 'error').mockImplementation(() => {})
    const frame = document.getElementById('creative-workspace-content')
    const state = frame.querySelector('[data-workspace-navigation-state]')
    state.dataset.creativeId = '5'
    state.dataset.creativePath = '[1,4,5]'
    window.history.replaceState({}, '', '/creatives?id=5')

    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(controller.pendingRevealPath).toEqual([1, 4, 5])
    expect(controller.expandedCreativeIds.has('4')).toBe(false)

    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        creatives: [{
          id: 1,
          label: 'Root',
          url: '/creatives?id=1',
          has_children: true,
          children: [{ id: 4, label: 'Recovered branch', url: '/creatives?id=4', has_children: true, children: [] }],
        }],
      }),
    })
    await controller.load({ showLoading: false, syncChat: false })

    const requestUrl = fetchMock.mock.calls[2][0]
    expect(new URL(requestUrl, window.location.origin).searchParams.getAll('expand[]')).toEqual(['1', '2', '3', '4', '5'])
    expect(controller.pendingRevealPath).toBeNull()
    expect(document.querySelector('[data-creative-id="4"] a').classList.contains('is-current')).toBe(true)
    console.error.mockRestore()
  })

  test('does not replace an explicitly opened chat during a background tree refresh', async () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        creatives: [{
          id: 1,
          label: 'Refreshed root',
          url: '/creatives?id=1',
          children: [{ id: 2, label: 'Current branch', url: '/creatives?id=2', children: [] }],
        }],
      }),
    })

    document.dispatchEvent(new CustomEvent('workspace-tree:invalidate'))
    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(document.querySelector('[data-creative-id="1"] > div > a').textContent).toBe('Refreshed root')
    expect(chatListener).not.toHaveBeenCalled()

    const frame = document.getElementById('creative-workspace-content')
    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))
    expect(chatListener).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2', workspaceSync: true }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('does not dispatch stale frame chat state after a delayed initial tree load', async () => {
    controller.disconnect()
    application.stop()

    let resolveFetch
    fetchMock.mockReset()
    fetchMock.mockReturnValue(new Promise((resolve) => {
      resolveFetch = resolve
    }))
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)

    application = Application.start()
    application.register('workspace-tree', WorkspaceTreeController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    resolveFetch({
      ok: true,
      json: async () => ({ creatives: [] }),
    })
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))

    const controllerElement = document.querySelector('[data-controller="workspace-tree"]')
    controller = application.getControllerForElementAndIdentifier(controllerElement, 'workspace-tree')
    expect(chatListener).not.toHaveBeenCalled()
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('does not reopen an invalidated chat from stale frame state after tree refresh', async () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ creatives: [] }),
    })

    document.dispatchEvent(new CustomEvent('creative-destroyed', {
      detail: { creativeIds: ['2'] },
    }))
    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(chatListener).not.toHaveBeenCalled()
    expect(document.querySelector('.creative-workspace-tree-link.is-current')).toBeNull()

    chatListener.mockClear()
    document.getElementById('creative-workspace-content')
      .dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))
    expect(chatListener).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: undefined, workspaceSync: true }),
    }))
    expect(chatListener).not.toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2' }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('restores a re-shared creative after a successful tree refresh proves access', async () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        creatives: [{
          id: 1,
          label: 'Root',
          url: '/creatives?id=1',
          children: [{ id: 2, label: 'Re-shared branch', url: '/creatives?id=2', children: [] }],
        }],
      }),
    })

    document.dispatchEvent(new CustomEvent('workspace-tree:invalidate', {
      detail: { creativeIds: ['2'] },
    }))
    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))

    chatListener.mockClear()
    document.getElementById('creative-workspace-content')
      .dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(chatListener).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2', workspaceSync: true }),
    }))
    expect(document.querySelector('[data-creative-id="2"] a').classList.contains('is-current')).toBe(true)
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('restores a re-granted leaf creative from an authoritative frame response', async () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        creatives: [{ id: 1, label: 'Root', url: '/creatives?id=1', children: [] }],
      }),
    })

    document.dispatchEvent(new CustomEvent('workspace-tree:invalidate', {
      detail: { creativeIds: ['2'] },
    }))
    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(controller.invalidatedCreativeIds.has('2')).toBe(true)

    chatListener.mockClear()
    const frame = document.getElementById('creative-workspace-content')
    frame.dispatchEvent(new CustomEvent('turbo:before-fetch-request', { bubbles: true }))
    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(controller.invalidatedCreativeIds.has('2')).toBe(false)
    expect(chatListener).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2', workspaceSync: true }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('does not restore a leaf from a frame request started before invalidation', async () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ creatives: [] }),
    })

    const frame = document.getElementById('creative-workspace-content')
    frame.dispatchEvent(new CustomEvent('turbo:before-fetch-request', { bubbles: true }))
    document.dispatchEvent(new CustomEvent('workspace-tree:invalidate', {
      detail: { creativeIds: ['2'] },
    }))
    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))

    chatListener.mockClear()
    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(controller.invalidatedCreativeIds.has('2')).toBe(true)
    expect(chatListener).not.toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2' }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('never restores destroyed creatives from an authoritative frame response', async () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ creatives: [] }),
    })

    document.dispatchEvent(new CustomEvent('creative-destroyed', {
      detail: { creativeIds: ['2'] },
    }))
    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))

    chatListener.mockClear()
    const frame = document.getElementById('creative-workspace-content')
    frame.dispatchEvent(new CustomEvent('turbo:before-fetch-request', { bubbles: true }))
    frame.dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(controller.invalidatedCreativeIds.has('2')).toBe(true)
    expect(chatListener).not.toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2' }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('does not restore access from a tree request started before invalidation', async () => {
    let resolveStaleFetch
    fetchMock.mockReturnValueOnce(new Promise((resolve) => {
      resolveStaleFetch = resolve
    }))
    fetchMock.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ creatives: [] }),
    })
    const staleLoad = controller.load({ showLoading: false, syncChat: false })

    document.dispatchEvent(new CustomEvent('workspace-tree:invalidate', {
      detail: { creativeIds: ['2'] },
    }))
    resolveStaleFetch({
      ok: true,
      json: async () => ({
        creatives: [{
          id: 1,
          label: 'Stale root',
          url: '/creatives?id=1',
          children: [{ id: 2, label: 'Stale branch', url: '/creatives?id=2', children: [] }],
        }],
      }),
    })
    await staleLoad

    expect(controller.invalidatedCreativeIds.has('2')).toBe(true)

    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(controller.invalidatedCreativeIds.has('2')).toBe(true)
  })

  test('keeps destroyed creatives invalidated when a stale tree response contains them', async () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)

    document.dispatchEvent(new CustomEvent('creative-destroyed', {
      detail: { creativeIds: ['2'] },
    }))
    await new Promise((resolve) => setTimeout(resolve, 120))
    await new Promise((resolve) => setTimeout(resolve, 0))

    chatListener.mockClear()
    document.getElementById('creative-workspace-content')
      .dispatchEvent(new CustomEvent('turbo:frame-load', { bubbles: true }))

    expect(chatListener).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: undefined, workspaceSync: true }),
    }))
    expect(chatListener).not.toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId: '2' }),
    }))
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('does not optimistically open an invalidated tree link', () => {
    const chatListener = jest.fn()
    document.addEventListener('creative-comments-click', chatListener)
    const rootLink = document.querySelector('[data-creative-id="1"] > div > a')
    controller.rememberInvalidatedCreativeIds({ detail: { creativeIds: ['1'] } })

    rootLink.dispatchEvent(new MouseEvent('click', { bubbles: true, button: 0, cancelable: true }))

    expect(chatListener).not.toHaveBeenCalled()
    expect(document.querySelector('[data-creative-id="2"] a').classList.contains('is-current')).toBe(true)
    document.removeEventListener('creative-comments-click', chatListener)
  })

  test('reloads the center frame when a history restore renders mismatched state', async () => {
    const frame = document.getElementById('creative-workspace-content')
    window.history.replaceState({}, '', '/creatives?id=5')

    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'restore' } }))
    document.dispatchEvent(new Event('turbo:render'))
    await new Promise((resolve) => requestAnimationFrame(resolve))

    expect(frame.src).toBe(window.location.href)
  })

  test('reloads the center frame when a history restore renders no navigation state', async () => {
    const frame = document.getElementById('creative-workspace-content')
    frame.innerHTML = ''

    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'restore' } }))
    document.dispatchEvent(new Event('turbo:render'))
    await new Promise((resolve) => requestAnimationFrame(resolve))

    expect(frame.src).toBe(window.location.href)
  })

  test('leaves the center frame alone when a restore matches the URL', async () => {
    const frame = document.getElementById('creative-workspace-content')

    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'restore' } }))
    document.dispatchEvent(new Event('turbo:render'))
    await new Promise((resolve) => requestAnimationFrame(resolve))

    expect(frame.src).toBeUndefined()
  })

  test('does not reload the frame for non-restore visits with transient mismatches', async () => {
    const frame = document.getElementById('creative-workspace-content')
    window.history.replaceState({}, '', '/creatives?id=5')

    document.dispatchEvent(new CustomEvent('turbo:visit', { detail: { action: 'advance' } }))
    document.dispatchEvent(new Event('turbo:render'))
    await new Promise((resolve) => requestAnimationFrame(resolve))

    expect(frame.src).toBeUndefined()
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
