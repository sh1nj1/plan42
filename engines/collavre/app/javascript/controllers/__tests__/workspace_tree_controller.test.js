/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import { jest } from '@jest/globals'
import WorkspaceTreeController from '../workspace_tree_controller'

describe('WorkspaceTreeController', () => {
  let application
  let fetchMock

  beforeEach(async () => {
    fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        creatives: [
          {
            id: 1,
            label: 'Root',
            url: '/creatives/1',
            children: [
              { id: 2, label: 'Current branch', url: '/creatives/2', children: [] },
            ],
          },
        ],
      }),
    })
    global.fetch = fetchMock
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
    `

    application = Application.start()
    application.register('workspace-tree', WorkspaceTreeController)
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))
  })

  afterEach(() => {
    application.stop()
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
