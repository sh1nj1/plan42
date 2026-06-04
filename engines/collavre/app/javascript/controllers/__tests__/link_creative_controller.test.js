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
    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    expect(browse).toHaveBeenLastCalledWith('1')
    const child = document.querySelector('.link-tree-children .link-tree-item .link-tree-label')
    expect(child.textContent).toBe('Child')

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
})
