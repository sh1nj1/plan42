/**
 * @jest-environment jsdom
 */
import {
  findWorkspaceItem,
  hasKnownWorkspaceCycle,
  showWorkspaceDropPreview,
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

  // The hit test answers in the move vocabulary and the stylesheet is written in
  // the presentation one. Building the class name from the direction produced
  // `drag-over-up` / `drag-over-down`: no rule matched them, so up and down
  // drops drew no indicator, and no cleanup removed them, so they piled up.
  test('previews with the class names the stylesheet defines', () => {
    const row = document.querySelector('.creative-workspace-tree-row')

    showWorkspaceDropPreview(row, 'up')
    expect([ ...row.classList ]).toContain('drag-over-top')

    showWorkspaceDropPreview(row, 'down')
    expect([ ...row.classList ]).toContain('drag-over-bottom')

    showWorkspaceDropPreview(row, 'child')
    expect([ ...row.classList ]).toContain('drag-over-child')
  })

  test('leaves no preview class behind across directions', () => {
    const row = document.querySelector('.creative-workspace-tree-row')
    const before = [ ...row.classList ]

    ;[ 'up', 'down', 'child', 'up' ].forEach((direction) => {
      const clear = showWorkspaceDropPreview(row, direction)
      expect([ ...row.classList ].filter((name) => name.startsWith('drag-over'))).toHaveLength(1)
      clear()
      expect([ ...row.classList ]).toEqual(before)
    })
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
