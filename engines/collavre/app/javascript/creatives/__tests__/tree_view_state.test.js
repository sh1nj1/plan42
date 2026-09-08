/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

jest.unstable_mockModule('../../lib/api/creatives', () => ({ loadChildren: jest.fn() }))
jest.unstable_mockModule('../tree_renderer', () => ({
  renderCreativeTree: jest.fn(),
  dispatchCreativeTreeUpdated: jest.fn(),
}))

const { loadChildren } = await import('../../lib/api/creatives')
const { renderCreativeTree } = await import('../tree_renderer')
const { captureCreativeTreeViewState, restoreCreativeTreeViewState } = await import('../tree_view_state')

function row(id, expanded = false) {
  return `
    <creative-tree-row creative-id="${id}" ${expanded ? 'expanded' : ''}>
      <div class="creative-tree"><button id="toggle-${id}">Toggle</button></div>
    </creative-tree-row>
    <div id="creative-children-${id}" style="display: ${expanded ? '' : 'none'}"></div>
  `
}

describe('creative tree view state', () => {
  test('restores expansion, focus, and the workspace main scroll position', () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}${row('2')}</div></main>`
    const main = document.querySelector('main')
    const tree = document.getElementById('creatives')
    main.scrollTop = 180
    document.getElementById('toggle-2').focus()
    const state = captureCreativeTreeViewState(tree)

    tree.innerHTML = `${row('1')}${row('2', true)}`
    main.scrollTop = 0
    restoreCreativeTreeViewState(tree, state)

    expect(tree.querySelector('creative-tree-row[creative-id="1"]').hasAttribute('expanded')).toBe(true)
    expect(tree.querySelector('creative-tree-row[creative-id="2"]').hasAttribute('expanded')).toBe(false)
    expect(document.getElementById('creative-children-1').style.display).toBe('')
    expect(document.getElementById('creative-children-2').style.display).toBe('none')
    expect(main.scrollTop).toBe(180)
    expect(document.activeElement.id).toBe('toggle-2')
  })

  // A hover expansion is never persisted, so the reloaded payload renders that
  // branch unloaded. Revealing the empty container would leave it looking open
  // but blank until the user collapsed and reopened it.
  test('reloads the children of a branch the refreshed payload left unloaded', async () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}</div></main>`
    const tree = document.getElementById('creatives')
    const state = captureCreativeTreeViewState(tree)

    tree.innerHTML = `
      <creative-tree-row creative-id="1"></creative-tree-row>
      <div id="creative-children-1" class="creative-children" style="display:none"
           data-loaded="false" data-load-url="/creatives/1/children.json"></div>
    `
    const container = document.getElementById('creative-children-1')
    loadChildren.mockResolvedValue({ creatives: [{ id: 2 }] })

    restoreCreativeTreeViewState(tree, state)
    await Promise.resolve()
    await Promise.resolve()

    expect(loadChildren).toHaveBeenCalledWith('/creatives/1/children.json')
    expect(renderCreativeTree).toHaveBeenCalledWith(container, [{ id: 2 }])
    expect(container.dataset.loaded).toBe('true')
    expect(container.style.display).toBe('')
    expect(tree.querySelector('creative-tree-row[creative-id="1"]').hasAttribute('expanded')).toBe(true)
  })

  test('leaves an expanded row alone when its children container is gone', () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}</div></main>`
    const tree = document.getElementById('creatives')
    const state = captureCreativeTreeViewState(tree)

    tree.innerHTML = '<creative-tree-row creative-id="1"></creative-tree-row>'
    loadChildren.mockClear()

    restoreCreativeTreeViewState(tree, state)

    expect(loadChildren).not.toHaveBeenCalled()
  })

  test('ignores rows and controls that disappear during reload', () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}</div></main>`
    const tree = document.getElementById('creatives')
    document.getElementById('toggle-1').focus()
    const state = captureCreativeTreeViewState(tree)

    tree.replaceChildren()

    expect(() => restoreCreativeTreeViewState(tree, state)).not.toThrow()
  })
})
