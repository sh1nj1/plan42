/**
 * @jest-environment jsdom
 */
import {
  applyWorkspaceMove,
  captureWorkspaceMove,
  findWorkspaceItem,
  hasKnownWorkspaceCycle,
  revertWorkspaceMove,
} from '../workspace_tree_dom'

function item(id, parentId = null, level = 1, children = '') {
  const parent = parentId ? ` data-parent-id="${parentId}"` : ''
  return `
    <li class="creative-workspace-tree-item" data-creative-id="${id}" data-level="${level}"${parent}>
      <div class="creative-workspace-tree-row" data-creative-id="${id}" data-level="${level}"${parent}></div>
      ${children}
    </li>
  `
}

function list(children) {
  return `<ul class="creative-workspace-tree-list">${children}</ul>`
}

describe('workspace tree move DOM', () => {
  let root

  beforeEach(() => {
    document.body.innerHTML = `<nav id="tree">${list([
      item('1', null, 1, list(item('2', '1', 2))),
      item('3'),
      item('4'),
    ].join(''))}</nav>`
    root = document.getElementById('tree')
  })

  test('blocks cycles whose ancestor chain is visible', () => {
    expect(hasKnownWorkspaceCycle({
      root,
      ids: ['1'],
      targetItem: findWorkspaceItem(root, '2'),
      direction: 'child',
    })).toBe(true)
    expect(hasKnownWorkspaceCycle({
      root,
      ids: ['1'],
      targetItem: findWorkspaceItem(root, '2'),
      direction: 'down',
    })).toBe(true)
  })

  test('allows an incomplete parent chain for server-side validation', () => {
    const target = findWorkspaceItem(root, '3')
    target.dataset.parentId = '999'

    expect(hasKnownWorkspaceCycle({ root, ids: ['1'], targetItem: target, direction: 'down' })).toBe(false)
  })

  test('blocks a selected target for single and bundled moves', () => {
    expect(hasKnownWorkspaceCycle({
      root,
      ids: ['3', '4'],
      targetItem: findWorkspaceItem(root, '4'),
      direction: 'up',
    })).toBe(true)
  })

  test('moves a subtree as a child and restores it after a failure', () => {
    const source = findWorkspaceItem(root, '1')
    const target = findWorkspaceItem(root, '3')
    const originalList = source.parentNode
    const originalNext = source.nextSibling
    const snapshot = captureWorkspaceMove(source)

    applyWorkspaceMove(snapshot, target, 'child')

    expect(source.parentNode.parentNode).toBe(target)
    expect(source.dataset.parentId).toBe('3')
    expect(source.dataset.level).toBe('2')
    expect(findWorkspaceItem(root, '2').dataset.level).toBe('3')

    revertWorkspaceMove(snapshot)

    expect(source.parentNode).toBe(originalList)
    expect(source.nextSibling).toBe(originalNext)
    expect(source.dataset.parentId).toBeUndefined()
    expect(source.dataset.level).toBe('1')
    expect(findWorkspaceItem(root, '2').dataset.level).toBe('2')
    expect(target.querySelector(':scope > .creative-workspace-tree-list')).toBeNull()
  })

  test('moves before and after without changing the target level', () => {
    const source = findWorkspaceItem(root, '4')
    const target = findWorkspaceItem(root, '3')
    const snapshot = captureWorkspaceMove(source)

    applyWorkspaceMove(snapshot, target, 'up')
    expect([...source.parentNode.children].map((entry) => entry.dataset.creativeId)).toEqual(['1', '4', '3'])

    applyWorkspaceMove(snapshot, target, 'down')
    expect([...source.parentNode.children].map((entry) => entry.dataset.creativeId)).toEqual(['1', '3', '4'])
  })
})
