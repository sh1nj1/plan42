/**
 * @jest-environment jsdom
 */
import {
  findWorkspaceItem,
  hasKnownWorkspaceCycle,
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

})
