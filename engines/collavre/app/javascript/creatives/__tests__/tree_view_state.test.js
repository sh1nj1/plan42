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
const { expandBranchWithChildren } = await import('../branch_expansion')
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
  beforeEach(() => {
    loadChildren.mockReset()
    renderCreativeTree.mockReset()
    renderCreativeTree.mockImplementation((container, nodes) => {
      container.innerHTML = nodes.map((node) => row(String(node.id))).join('')
    })
  })

  test('restores expansion, focus, and the workspace main scroll position', async () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}${row('2')}</div></main>`
    const main = document.querySelector('main')
    const tree = document.getElementById('creatives')
    main.scrollTop = 180
    document.getElementById('toggle-2').focus()
    const state = captureCreativeTreeViewState(tree)

    tree.innerHTML = `${row('1')}${row('2', true)}`
    main.scrollTop = 0
    await restoreCreativeTreeViewState(tree, state)

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

    await restoreCreativeTreeViewState(tree, state)

    expect(loadChildren).toHaveBeenCalledWith('/creatives/1/children.json')
    expect(renderCreativeTree).toHaveBeenCalledWith(container, [{ id: 2 }])
    expect(container.dataset.loaded).toBe('true')
    expect(container.style.display).toBe('')
    expect(tree.querySelector('creative-tree-row[creative-id="1"]').hasAttribute('expanded')).toBe(true)
  })

  test('restores nested expansion and focus after loading each ancestor', async () => {
    document.body.innerHTML = `
      <main><div id="creatives">
        <creative-tree-row creative-id="1" expanded>
          <div><button id="toggle-1">Toggle</button></div>
        </creative-tree-row>
        <div id="creative-children-1" data-loaded="true">
          <creative-tree-row creative-id="2" expanded>
            <div><button id="toggle-2">Toggle</button></div>
          </creative-tree-row>
          <div id="creative-children-2" data-loaded="true"></div>
        </div>
      </div></main>
    `
    const tree = document.getElementById('creatives')
    document.getElementById('toggle-2').focus()
    const state = captureCreativeTreeViewState(tree)

    tree.innerHTML = `
      <creative-tree-row creative-id="1" has-children>
        <div><button id="toggle-1">Toggle</button></div>
      </creative-tree-row>
      <div id="creative-children-1" data-loaded="false" data-load-url="/children/1"></div>
    `
    loadChildren
      .mockResolvedValueOnce({ creatives: [{ id: 2 }] })
      .mockResolvedValueOnce({ creatives: [{ id: 3 }] })
    renderCreativeTree
      .mockImplementationOnce((container) => {
        container.innerHTML = `
          <creative-tree-row creative-id="2" has-children>
            <div><button id="toggle-2">Toggle</button></div>
          </creative-tree-row>
          <div id="creative-children-2" data-loaded="false" data-load-url="/children/2"></div>
        `
      })
      .mockImplementationOnce((container) => {
        container.innerHTML = row('3')
      })

    await restoreCreativeTreeViewState(tree, state)

    expect(loadChildren.mock.calls.map(([url]) => url)).toEqual(['/children/1', '/children/2'])
    expect(tree.querySelector('[creative-id="1"]').hasAttribute('expanded')).toBe(true)
    expect(tree.querySelector('[creative-id="2"]').hasAttribute('expanded')).toBe(true)
    expect(document.activeElement.id).toBe('toggle-2')
  })

  test('collapses a stale branch when lazy loading finds no children', async () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}</div></main>`
    const tree = document.getElementById('creatives')
    const state = captureCreativeTreeViewState(tree)

    tree.innerHTML = `
      <creative-tree-row creative-id="1" has-children expanded></creative-tree-row>
      <div id="creative-children-1" data-loaded="false" data-load-url="/children/1"></div>
    `
    loadChildren.mockResolvedValue({ creatives: [] })

    await restoreCreativeTreeViewState(tree, state)

    const restoredRow = tree.querySelector('[creative-id="1"]')
    const container = document.getElementById('creative-children-1')
    expect(restoredRow.hasAttribute('has-children')).toBe(false)
    expect(restoredRow.hasAttribute('expanded')).toBe(false)
    expect(container.dataset.loaded).toBe('true')
    expect(container.style.display).toBe('none')
  })

  test('leaves an expanded row alone when its children container is gone', async () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}</div></main>`
    const tree = document.getElementById('creatives')
    const state = captureCreativeTreeViewState(tree)

    tree.innerHTML = '<creative-tree-row creative-id="1"></creative-tree-row>'
    loadChildren.mockClear()

    await restoreCreativeTreeViewState(tree, state)

    expect(loadChildren).not.toHaveBeenCalled()
  })

  test('ignores rows and controls that disappear during reload', async () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}</div></main>`
    const tree = document.getElementById('creatives')
    document.getElementById('toggle-1').focus()
    const state = captureCreativeTreeViewState(tree)

    tree.replaceChildren()

    await expect(restoreCreativeTreeViewState(tree, state)).resolves.toBeUndefined()
  })

  test('stops an obsolete restoration before applying lazy children, scroll, or focus', async () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1', true)}</div></main>`
    const main = document.querySelector('main')
    const tree = document.getElementById('creatives')
    main.scrollTop = 140
    document.getElementById('toggle-1').focus()
    const state = captureCreativeTreeViewState(tree)
    tree.innerHTML = `
      <creative-tree-row creative-id="1" has-children>
        <div><button id="replacement-toggle">Toggle</button></div>
      </creative-tree-row>
      <div id="creative-children-1" data-loaded="false" data-load-url="/children/1"></div>
    `
    main.scrollTop = 0
    let releaseChildren
    loadChildren.mockReturnValue(new Promise((resolve) => {
      releaseChildren = () => resolve({ creatives: [{ id: 2 }] })
    }))
    let current = true

    const restoration = restoreCreativeTreeViewState(tree, state, { isCurrent: () => current })
    current = false
    releaseChildren()
    await restoration

    expect(renderCreativeTree).not.toHaveBeenCalled()
    expect(tree.querySelector('[creative-id="1"]').hasAttribute('expanded')).toBe(false)
    expect(main.scrollTop).toBe(0)
    expect(document.activeElement.id).not.toBe('replacement-toggle')
  })

  // A row's controls are rebuilt without their ids on some renders, so the
  // captured position is the only way back to the same control.
  test('restores an anonymous control by its position in the row', async () => {
    document.body.innerHTML = `
      <main><div id="creatives">
        <creative-tree-row creative-id="1">
          <button>First</button><button>Second</button>
        </creative-tree-row>
      </div></main>
    `
    const tree = document.getElementById('creatives')
    tree.querySelectorAll('button')[1].focus()

    const state = captureCreativeTreeViewState(tree)
    expect(state.focus).toMatchObject({ creativeId: '1', controlId: null, controlIndex: 1 })

    tree.innerHTML = `
      <creative-tree-row creative-id="1">
        <button>First</button><button>Second</button>
      </creative-tree-row>
    `
    await restoreCreativeTreeViewState(tree, state)

    expect(document.activeElement.textContent).toBe('Second')
  })

  test('restores a scroll position captured without any expansion record', async () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1')}</div></main>`
    const main = document.querySelector('main')
    const tree = document.getElementById('creatives')

    await restoreCreativeTreeViewState(tree, { scrolling: main, scrollTop: 42, focus: null })

    expect(main.scrollTop).toBe(42)
  })
  test('an already superseded restore does not load or change any row', async () => {
    document.body.innerHTML = `<main><div id="creatives">${row('1')}</div></main>`
    const tree = document.getElementById('creatives')
    const state = captureCreativeTreeViewState(tree)
    state.expansion[0].expanded = true
    await restoreCreativeTreeViewState(tree, state, { isCurrent: () => false })
    expect(loadChildren).not.toHaveBeenCalled()
    expect(tree.querySelector('creative-tree-row').hasAttribute('expanded')).toBe(false)
  })

  test('branch expansion tolerates a missing container and a missing child payload', async () => {
    document.body.innerHTML = `<div id="creatives">${row('1')}</div>`
    const creative = document.querySelector('creative-tree-row')
    expect(await expandBranchWithChildren(creative, null)).toBe(false)
    const container = document.getElementById('creative-children-1')
    container.dataset.loadUrl = '/creatives/1/children.json'
    loadChildren.mockResolvedValue(undefined)
    expect(await expandBranchWithChildren(creative, container)).toBe(false)
    expect(container.dataset.loaded).toBe('true')
    expect(creative.hasAttribute('expanded')).toBe(false)
  })

})
