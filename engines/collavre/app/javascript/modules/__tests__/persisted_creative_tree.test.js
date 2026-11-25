/**
 * @jest-environment jsdom
 */
import { bindPersistedTree } from '../persisted_creative_tree'

function treeInside(rowComponent) {
  const tree = document.createElement('div')
  tree.className = 'creative-tree'
  rowComponent?.appendChild(tree)
  return tree
}

describe('bindPersistedTree', () => {
  test('ignores a missing tree', () => {
    expect(() => bindPersistedTree(null, { id: 1 }, '', null)).not.toThrow()
  })

  test('binds a root row', () => {
    const rowComponent = document.createElement('creative-tree-row')
    const tree = treeInside(rowComponent)
    tree.dataset.level = '2'

    bindPersistedTree(tree, { id: 9, description: 'hello' }, '', null)

    expect(tree.id).toBe('creative-9')
    expect(tree.dataset.parentId).toBe('')
    expect(rowComponent.getAttribute('creative-id')).toBe('9')
    expect(rowComponent.getAttribute('link-url')).toBe('/creatives/9')
    expect(rowComponent.level).toBe(2)
    expect(rowComponent.isRoot).toBe(true)
    expect(rowComponent.hasAttribute('is-root')).toBe(true)
  })

  test('binds the fallback row under a parent and keeps the rendered row', () => {
    const tree = treeInside(null)
    const existing = document.createElement('div')
    existing.className = 'creative-row'
    tree.appendChild(existing)
    const fallback = document.createElement('creative-tree-row')

    bindPersistedTree(tree, { id: 9 }, '4', fallback)

    expect(fallback.getAttribute('parent-id')).toBe('4')
    expect(fallback.isRoot).toBe(false)
    expect(fallback.hasAttribute('level')).toBe(false)
    expect(tree.querySelectorAll('.creative-row')).toHaveLength(1)
  })
})
