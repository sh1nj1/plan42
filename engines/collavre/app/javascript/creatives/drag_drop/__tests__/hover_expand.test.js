/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { writeDragData } from '../../../lib/dnd/envelope'
import { resetDragSessionCache } from '../../../lib/dnd/session'
import { handleDragLeave, handleDragOver } from '../event_handlers'

function transfer() {
  const values = new Map()
  return {
    dropEffect: 'none',
    get types() { return [...values.keys()] },
    getData(type) { return values.get(type) || '' },
    setData(type, value) { values.set(type, String(value)) },
  }
}

function event(tree, dataTransfer) {
  return {
    target: tree,
    dataTransfer,
    clientX: 10,
    clientY: 50,
    shiftKey: false,
    preventDefault: jest.fn(),
  }
}

describe('right creative tree hover expansion', () => {
  beforeEach(() => {
    jest.useFakeTimers()
    window.localStorage.clear()
    window.sessionStorage.clear()
    resetDragSessionCache()
    document.body.innerHTML = `
      <creative-tree-row creative-id="2" has-children>
        <div id="creative-2" class="creative-tree" draggable="true"></div>
      </creative-tree-row>
      <div id="creative-children-2" style="display:none"></div>
    `
    document.getElementById('creative-2').getBoundingClientRect = () => ({ top: 0, height: 100 })
  })

  afterEach(() => jest.useRealTimers())

  test('expands a collapsed child target after 600ms', () => {
    const dataTransfer = transfer()
    writeDragData(dataTransfer, {
      kind: 'creative', ids: ['1'], payload: { creativeId: '1', treeId: 'creative-1' },
    })
    const tree = document.getElementById('creative-2')

    handleDragOver(event(tree, dataTransfer))
    jest.advanceTimersByTime(599)
    expect(tree.closest('creative-tree-row').hasAttribute('expanded')).toBe(false)
    jest.advanceTimersByTime(1)

    expect(tree.closest('creative-tree-row').hasAttribute('expanded')).toBe(true)
    expect(document.getElementById('creative-children-2').style.display).toBe('')
  })

  test('cancels expansion after leaving the target', () => {
    const dataTransfer = transfer()
    writeDragData(dataTransfer, {
      kind: 'creative', ids: ['1'], payload: { creativeId: '1', treeId: 'creative-1' },
    })
    const tree = document.getElementById('creative-2')

    handleDragOver(event(tree, dataTransfer))
    handleDragLeave(event(tree, dataTransfer))
    jest.advanceTimersByTime(600)

    expect(tree.closest('creative-tree-row').hasAttribute('expanded')).toBe(false)
  })
})
