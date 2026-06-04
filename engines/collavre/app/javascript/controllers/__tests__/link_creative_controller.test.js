/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const browse = jest.fn()
const search = jest.fn()

jest.unstable_mockModule('../../lib/api/creatives', () => ({
  default: { browse, search },
  browse,
  search,
}))

const { Application } = await import('@hotwired/stimulus')
const LinkCreativeController = (await import('../link_creative_controller')).default

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

const installController = async () => {
  document.body.innerHTML = `
    <div id="link-creative-modal" class="common-popup" style="display:none;" data-controller="link-creative"
         data-link-creative-loading-text="Loading…"
         data-link-creative-no-results-text="No results"
         data-link-creative-empty-text="Empty"
         data-link-creative-expand-text="Expand">
      <button type="button" class="popup-close-btn" data-link-creative-target="close">&times;</button>
      <input type="text" data-link-creative-target="input">
      <ul class="common-popup-list link-creative-list" data-popup-list data-link-creative-target="list"></ul>
    </div>`

  const application = Application.start()
  application.register('link-creative', LinkCreativeController)
  await flush() // Stimulus connects asynchronously
  const element = document.getElementById('link-creative-modal')
  const controller = application.getControllerForElementAndIdentifier(element, 'link-creative')
  return { application, element, controller }
}

const rect = { left: 0, top: 0, bottom: 0, right: 0, width: 0, height: 0 }

describe('LinkCreativeController picker', () => {
  beforeAll(() => {
    // jsdom does not implement scrollIntoView (used when highlighting a node).
    window.HTMLElement.prototype.scrollIntoView = jest.fn()
  })

  afterEach(() => {
    document.body.innerHTML = ''
    jest.clearAllMocks()
  })

  test('renders a browsable tree on open with toggles for nodes that have children', async () => {
    browse.mockResolvedValue([
      { id: 1, description: 'Root A', progress: 0, has_children: true },
      { id: 2, description: 'Root B', progress: 0, has_children: false },
    ])

    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush()

    expect(browse).toHaveBeenCalledWith(null)
    const items = document.querySelectorAll('.link-tree-item')
    expect(items).toHaveLength(2)
    // First node is expandable, second is a leaf
    expect(items[0].querySelector('.link-tree-toggle:not(.link-tree-toggle-empty)')).not.toBeNull()
    expect(items[1].querySelector('.link-tree-toggle-empty')).not.toBeNull()
    expect(items[0].querySelector('.link-tree-label').textContent).toBe('Root A')

    application.stop()
  })

  test('expands a node lazily, loading its children on toggle click', async () => {
    browse
      .mockResolvedValueOnce([{ id: 1, description: 'Root A', progress: 0, has_children: true }])
      .mockResolvedValueOnce([{ id: 5, description: 'Child', progress: 0, has_children: false }])

    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush()

    const toggle = document.querySelector('.link-tree-toggle:not(.link-tree-toggle-empty)')
    // Collapsed toggle renders the same SVG chevron as the main creative tree.
    expect(toggle.querySelector('svg')).not.toBeNull()
    expect(toggle.textContent).toBe('')

    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    expect(browse).toHaveBeenLastCalledWith('1')
    const child = document.querySelector('.link-tree-children .link-tree-item .link-tree-label')
    expect(child.textContent).toBe('Child')
    // Expanded toggle still renders an SVG chevron (icon swapped, not text).
    expect(toggle.querySelector('svg')).not.toBeNull()

    application.stop()
  })

  test('does not search below the 2-character threshold', async () => {
    browse.mockResolvedValue([])
    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush()

    controller.inputTarget.value = 'a'
    controller.search()
    await flush()

    expect(search).not.toHaveBeenCalled()

    application.stop()
  })

  test('renders flat results with a clickable breadcrumb at >= 2 characters', async () => {
    browse.mockResolvedValue([])
    search.mockResolvedValue([
      {
        id: 9,
        description: 'Deep Leaf',
        progress: 0,
        path: [
          { id: 1, description: 'Root' },
          { id: 3, description: 'Mid' },
        ],
      },
    ])

    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush()

    controller.inputTarget.value = 'lea'
    controller.search()
    await flush()

    expect(search).toHaveBeenCalledWith('lea', { simple: true })
    const result = document.querySelector('.link-result-item')
    expect(result.querySelector('.link-result-label').textContent).toBe('Deep Leaf')
    const crumbs = result.querySelectorAll('.link-crumb')
    expect(Array.from(crumbs).map((c) => c.textContent)).toEqual(['Root', 'Mid'])

    application.stop()
  })

  test('masks restricted ancestors in the breadcrumb and keeps them non-clickable', async () => {
    browse.mockResolvedValue([])
    search.mockResolvedValue([
      {
        id: 9,
        description: 'Deep Leaf',
        progress: 0,
        path: [
          { id: 1, description: null, restricted: true },
          { id: 3, description: 'Mid' },
        ],
      },
    ])

    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush()

    controller.inputTarget.value = 'lea'
    controller.search()
    await flush()

    const restricted = document.querySelector('.link-crumb-restricted')
    expect(restricted).not.toBeNull()
    expect(restricted.tagName).toBe('SPAN') // not a button -> not clickable
    expect(restricted.textContent).toBe('…')

    application.stop()
  })

  test('localizes the expand toggle aria-label from the data attribute', async () => {
    browse.mockResolvedValue([{ id: 1, description: 'Root A', progress: 0, has_children: true }])

    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush()

    const toggle = document.querySelector('.link-tree-toggle:not(.link-tree-toggle-empty)')
    expect(toggle.getAttribute('aria-label')).toBe('Expand')

    application.stop()
  })

  test('breadcrumb maps an origin id back to its linked shell root and expands it', async () => {
    // Root browse returns a linked shell (id 100) whose effective origin is 1.
    browse
      .mockResolvedValueOnce([
        { id: 100, description: 'Shared', progress: 0, has_children: true, origin_id: 1 },
      ])
      // Expanding the shell loads the origin's real children (id 3).
      .mockResolvedValueOnce([{ id: 3, description: 'Mid', progress: 0, has_children: false }])
    // Search match's breadcrumb carries origin ids (root crumb id 1 == shell origin).
    search.mockResolvedValue([
      {
        id: 9,
        description: 'Deep Leaf',
        progress: 0,
        path: [
          { id: 1, description: 'Shared' },
          { id: 3, description: 'Mid' },
        ],
      },
    ])

    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush() // caches root nodes (the shell)

    controller.inputTarget.value = 'lea'
    controller.search()
    await flush()

    // Click the second crumb (Mid): chain = [origin id 1], target = 3.
    const crumbs = document.querySelectorAll('.link-crumb')
    crumbs[1].dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    // The shell (id 100) must have been expanded via its origin id (1), not skipped.
    expect(browse).toHaveBeenLastCalledWith('100')
    const mid = document.querySelector('.link-tree-children .link-tree-item[data-id="3"]')
    expect(mid).not.toBeNull()

    application.stop()
  })

  test('reveal_path expands local folders to reach a nested linked shell', async () => {
    // The shell is nested under the user's own (collapsed) folder, so root
    // browse returns only that folder — not the shell.
    browse
      .mockResolvedValueOnce([
        { id: 50, description: 'Local Folder', progress: 0, has_children: true },
      ])
      // Expanding the local folder reveals the shell (id 100, origin 1).
      .mockResolvedValueOnce([
        { id: 100, description: 'Shared', progress: 0, has_children: true, origin_id: 1 },
      ])
      // Expanding the shell loads the origin's real children (id 3).
      .mockResolvedValueOnce([{ id: 3, description: 'Mid', progress: 0, has_children: false }])
    // Origin-space breadcrumb (ids 1,3) plus the user-local reveal path to the shell.
    search.mockResolvedValue([
      {
        id: 9,
        description: 'Deep Leaf',
        progress: 0,
        // Keyed by origin ancestor: origin 1's shell is reached via [50, 100].
        reveal_path: { 1: [50, 100] },
        path: [
          { id: 1, description: 'Shared' },
          { id: 3, description: 'Mid' },
        ],
      },
    ])

    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush() // caches root nodes (the local folder)

    controller.inputTarget.value = 'lea'
    controller.search()
    await flush()

    // Click the second crumb (Mid): anchor at origin 1 -> chain = [50, 100], target = 3.
    const crumbs = document.querySelectorAll('.link-crumb')
    crumbs[1].dispatchEvent(new MouseEvent('click', { bubbles: true }))
    for (let i = 0; i < 5; i++) await flush()

    // Local folder (50) and shell (100) were both expanded to surface the hit.
    expect(browse).toHaveBeenCalledWith('50')
    expect(browse).toHaveBeenCalledWith('100')
    const mid = document.querySelector('.link-tree-children .link-tree-item[data-id="3"]')
    expect(mid).not.toBeNull()

    application.stop()
  })

  test('a higher ancestor crumb resolves through its own shell, not the deepest one', async () => {
    // The user holds a shell for both origin 1 (under folder 50) and origin 3
    // (under folder 60). Root browse returns both local folders.
    browse
      .mockResolvedValueOnce([
        { id: 50, description: 'Folder A', progress: 0, has_children: true },
        { id: 60, description: 'Folder D', progress: 0, has_children: true },
      ])
      // Expanding folder A (50) reveals origin 1's shell (id 100).
      .mockResolvedValueOnce([
        { id: 100, description: 'Ancestor', progress: 0, has_children: true, origin_id: 1 },
      ])
      // Expanding that shell loads origin 1's children.
      .mockResolvedValueOnce([{ id: 3, description: 'Descendant', progress: 0, has_children: false }])
    // Per-origin reveal map: each origin ancestor maps to its own shell path.
    search.mockResolvedValue([
      {
        id: 9,
        description: 'Deep Leaf',
        progress: 0,
        reveal_path: { 1: [50, 100], 3: [60, 200] },
        path: [
          { id: 1, description: 'Ancestor' },
          { id: 3, description: 'Descendant' },
        ],
      },
    ])

    const { application, controller } = await installController()
    controller.open(rect, jest.fn(), jest.fn())
    await flush() // caches root nodes (both local folders)

    controller.inputTarget.value = 'lea'
    controller.search()
    await flush()

    // Click the FIRST crumb (Ancestor, id 1): must anchor at origin 1's shell
    // (folder 50 -> shell 100), NOT the deeper origin 3 shell (folder 60).
    const crumbs = document.querySelectorAll('.link-crumb')
    crumbs[0].dispatchEvent(new MouseEvent('click', { bubbles: true }))
    for (let i = 0; i < 5; i++) await flush()

    expect(browse).toHaveBeenCalledWith('50')
    expect(browse).toHaveBeenCalledWith('100')
    expect(browse).not.toHaveBeenCalledWith('60')
    expect(browse).not.toHaveBeenCalledWith('200')

    application.stop()
  })

  test('selecting a tree row invokes the callback with id and label', async () => {
    browse.mockResolvedValue([{ id: 7, description: 'Pick Me', progress: 0, has_children: false }])
    const onSelect = jest.fn()

    const { application, controller } = await installController()
    controller.open(rect, onSelect, jest.fn())
    await flush()

    document.querySelector('.link-tree-row').dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    expect(onSelect).toHaveBeenCalledWith({ id: 7, label: 'Pick Me' })

    application.stop()
  })

  test('selecting a linked shell row emits the effective origin id', async () => {
    // Shell row (id 100) whose effective origin is 1; selecting it must hand the
    // origin id to consumers so a new link is based on the real shared creative,
    // not the user's shell (which would corrupt the permission base).
    browse.mockResolvedValue([
      { id: 100, description: 'Shared', progress: 0, has_children: false, origin_id: 1 },
    ])
    const onSelect = jest.fn()

    const { application, controller } = await installController()
    controller.open(rect, onSelect, jest.fn())
    await flush()

    document.querySelector('.link-tree-row').dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    expect(onSelect).toHaveBeenCalledWith({ id: 1, label: 'Shared' })

    application.stop()
  })
})
