/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// The move itself belongs to T2's command layer, which has its own suite. Here
// only the wiring matters: which command handleDrop builds, when it declines to
// build one at all, and what it broadcasts once the command settles.
const createMoveContext = jest.fn(() => ({ context: true }))
const applyMove = jest.fn(() => ({ newParentId: '2' }))
const revertMove = jest.fn()
const runMoveWithDomRecovery = jest.fn()

jest.unstable_mockModule('../operations', () => ({
  createMoveContext,
  applyMove,
  revertMove,
  runMoveWithDomRecovery,
}))
jest.unstable_mockModule('../../../lib/api/drag_drop', () => ({
  sendNewOrder: jest.fn(),
  sendLinkedCreative: jest.fn(),
  sendTopicMove: jest.fn(),
}))
jest.unstable_mockModule('../indicator', () => ({
  initIndicator: jest.fn(),
  showLinkHover: jest.fn(),
  hideLinkHover: jest.fn(),
}))
jest.unstable_mockModule('../../topic_move_members_popup', () => ({
  showMissingMembersPopup: jest.fn(),
}))
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog: jest.fn() }))

const {
  addGlobalListeners,
  handleDragOver,
  handleDragStart,
  handleDrop,
  removeGlobalListeners,
} = await import('../event_handlers')
const { readDragData } = await import('../../../lib/dnd/envelope')
const { resetDragSessionCache } = await import('../../../lib/dnd/session')
const { resetDraggedState } = await import('../state')

const DROP_SIGNAL_STORAGE_KEY = 'collavre.dragDropSignal'
const DRAG_TOKEN_STORAGE_KEY = 'collavre.dragToken'

function row(id, { parentId = null, isRoot = false, level = 1 } = {}) {
  const parent = parentId ? ` parent-id="${parentId}"` : ''
  return `
    <creative-tree-row creative-id="${id}" level="${level}"${parent}${isRoot ? ' is-root' : ''}>
      <div class="creative-tree" id="creative-${id}" draggable="true">
        <span class="creative-content">Creative ${id}</span>
      </div>
    </creative-tree-row>
  `
}

function transfer() {
  const values = new Map()
  return {
    dropEffect: 'none',
    effectAllowed: 'none',
    setDragImage: jest.fn(),
    get types() { return [...values.keys()] },
    getData(type) { return values.get(type) || '' },
    setData(type, value) { values.set(type, String(value)) },
  }
}

function dragEvent(target, dataTransfer, { clientY = 50, shiftKey = false } = {}) {
  return { target, dataTransfer, clientX: 10, clientY, shiftKey, preventDefault: jest.fn() }
}

function tree(id) {
  return document.getElementById(`creative-${id}`)
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('right creative tree drop wiring', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    resetDragSessionCache()
    resetDraggedState()
    // T2 always answers with a full result; a mock that omits `succeededIds`
    // would let a real crash pass unnoticed here.
    runMoveWithDomRecovery.mockImplementation(({ command }) => Promise.resolve({
      command, status: 'success', ok: true, succeededIds: [...command.ids], failedIds: [], failures: [],
    }))
    document.body.innerHTML = `
      <div id="creatives">
        ${row('1', { isRoot: true })}
        <div class="creative-children" id="creative-children-1"></div>
        ${row('2', { isRoot: true })}
        ${row('3', { isRoot: true })}
        ${row('4', { isRoot: true })}
      </div>
    `
    document.getElementById('creative-children-1').appendChild(
      document.getElementById('creative-3').closest('creative-tree-row')
    )
    document.getElementById('creative-3').closest('creative-tree-row')
      .setAttribute('parent-id', '1')
    document.querySelectorAll('.creative-tree').forEach((element) => {
      element.getBoundingClientRect = () => ({ top: 0, height: 100 })
    })
  })

  afterEach(() => {
    resetDraggedState()
    jest.clearAllMocks()
    document.body.innerHTML = ''
  })

  test('publishes an envelope the shared reader accepts', () => {
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('1'), dataTransfer))

    expect(dataTransfer.effectAllowed).toBe('move')
    expect(readDragData(dataTransfer)).toEqual({
      kind: 'creative',
      ids: ['1'],
      payload: expect.objectContaining({
        creativeId: '1',
        treeId: 'creative-1',
        parentId: null,
        isRoot: true,
        sourceWindowId: expect.any(String),
      }),
    })
  })

  test('carries a multi-selection into the envelope and the command', async () => {
    document.body.insertAdjacentHTML('beforeend', `
      <input class="select-creative-checkbox" type="checkbox" value="1" checked>
      <input class="select-creative-checkbox" type="checkbox" value="2" checked>
    `)
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('1'), dataTransfer))
    expect(readDragData(dataTransfer).ids).toEqual(['1', '2'])

    handleDragOver(dragEvent(tree('4'), dataTransfer, { clientY: 50 }))
    handleDrop(dragEvent(tree('4'), dataTransfer, { clientY: 50 }))
    await flush()

    // A bundle keeps its own subtree intact, so no optimistic DOM move is staged.
    expect(applyMove).not.toHaveBeenCalled()
    expect(runMoveWithDomRecovery).toHaveBeenCalledWith(expect.objectContaining({
      command: { ids: ['1', '2'], targetId: '4', direction: 'child', mode: 'move' },
      moveContext: null,
    }))
  })

  test('stages an optimistic move and broadcasts once the command succeeds', async () => {
    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion, { once: true })
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('2'), dataTransfer))
    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 10 }))
    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 10 }))
    await flush()

    expect(createMoveContext).toHaveBeenCalled()
    expect(applyMove).toHaveBeenCalledWith(expect.objectContaining({ direction: 'up' }))
    expect(runMoveWithDomRecovery).toHaveBeenCalledWith({
      command: { ids: ['2'], targetId: '1', direction: 'up', mode: 'move' },
      moveContext: { context: true },
      attemptedParentId: '2',
    })
    expect(completion).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({
        creativeIds: ['2'], targetCreativeId: '1', direction: 'up', context: 'target',
      }),
    }))
    expect(window.localStorage.getItem(DROP_SIGNAL_STORAGE_KEY)).toBeNull()
  })

  test('links with shift without staging an optimistic move', async () => {
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('2'), dataTransfer, { shiftKey: true }))
    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 50, shiftKey: true }))
    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 50, shiftKey: true }))
    await flush()

    expect(applyMove).not.toHaveBeenCalled()
    expect(runMoveWithDomRecovery).toHaveBeenCalledWith(expect.objectContaining({
      command: { ids: ['2'], targetId: '1', direction: 'child', mode: 'link' },
    }))
  })

  test('stays silent when the command reports it did not move anything', async () => {
    runMoveWithDomRecovery.mockResolvedValue({
      status: 'failure', ok: false, succeededIds: [], failedIds: ['2'], failures: [],
    })
    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion, { once: true })
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('2'), dataTransfer))
    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await flush()

    expect(completion).not.toHaveBeenCalled()
  })

  test('reports a command that rejects outright', async () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    runMoveWithDomRecovery.mockRejectedValue(new Error('network down'))
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('2'), dataTransfer))
    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await flush()

    expect(consoleError).toHaveBeenCalledWith(
      'Failed to update order',
      expect.objectContaining({ message: 'network down' })
    )
    consoleError.mockRestore()
  })

  test('broadcasts to the originating window when the drag came from elsewhere', async () => {
    window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'token-under-test')
    resetDragSessionCache()
    const dataTransfer = transfer()
    dataTransfer.setData('application/x-collavre-creative', JSON.stringify({
      creativeId: '9',
      treeId: 'creative-9',
      token: 'token-under-test',
      sourceWindowId: 'other-window',
      selectedCreativeIds: [],
    }))

    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await flush()

    expect(runMoveWithDomRecovery).toHaveBeenCalledWith(expect.objectContaining({
      command: { ids: ['9'], targetId: '1', direction: 'child', mode: 'move' },
      moveContext: null,
    }))
  })

  // A partial view can hand back an envelope whose tree id no longer resolves,
  // so the row identity — not the tree id — has to catch the self drop.
  test('declines an envelope that resolves back onto its own row', async () => {
    window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'token-under-test')
    resetDragSessionCache()
    const dataTransfer = transfer()
    dataTransfer.setData('application/x-collavre-creative', JSON.stringify({
      creativeId: '1',
      treeId: 'creative-detached',
      token: 'token-under-test',
      sourceWindowId: 'other-window',
      selectedCreativeIds: [],
    }))

    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await flush()

    expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
  })

  test('ignores a drop carrying a kind the creative tree does not handle', async () => {
    const dataTransfer = transfer()
    dataTransfer.setData('application/x-context-id', '5')

    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await flush()

    expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
  })

  test('declines a drop whose target row cannot report a drop position', () => {
    const dataTransfer = transfer()
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 0 })

    handleDragStart(dragEvent(tree('2'), dataTransfer))
    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))

    expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
  })

  test('declines a drop onto the dragged row itself', () => {
    const dataTransfer = transfer()
    document.body.insertAdjacentHTML('beforeend', `
      <input class="select-creative-checkbox" type="checkbox" value="1" checked>
      <input class="select-creative-checkbox" type="checkbox" value="2" checked>
    `)

    handleDragStart(dragEvent(tree('1'), dataTransfer))
    // #creative-2 is inside the bundle, so it cannot also be the destination.
    handleDrop(dragEvent(tree('2'), dataTransfer, { clientY: 50 }))

    expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
  })

  test('declines a drop into a descendant the DOM can prove', () => {
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('1'), dataTransfer))
    handleDrop(dragEvent(tree('3'), dataTransfer, { clientY: 50 }))

    expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
  })

  // Only the parent chain can prove a cycle once a partial view hides the
  // subtree, so a row still in the DOM has to be walked upward.
  test('declines a drop under a descendant that is no longer nested in the DOM', () => {
    const detached = document.getElementById('creative-3').closest('creative-tree-row')
    document.getElementById('creatives').appendChild(detached)
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('1'), dataTransfer))
    handleDrop(dragEvent(tree('3'), dataTransfer, { clientY: 50 }))

    expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
  })

  // A row rendered without its id gives the cycle check nothing to compare, so
  // the drop is refused rather than sent to the server on a guess.
  test('declines a drop onto a row that names no creative', () => {
    const anonymous = document.getElementById('creative-4').closest('creative-tree-row')
    anonymous.removeAttribute('creative-id')
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('2'), dataTransfer))
    handleDrop(dragEvent(tree('4'), dataTransfer, { clientY: 50 }))

    expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
  })

  test('allows a sibling drop next to a row whose parent chain is unknown', async () => {
    const detached = document.getElementById('creative-3').closest('creative-tree-row')
    document.getElementById('creatives').appendChild(detached)
    detached.setAttribute('parent-id', '404')
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('2'), dataTransfer))
    handleDrop(dragEvent(tree('3'), dataTransfer, { clientY: 10 }))
    await flush()

    expect(runMoveWithDomRecovery).toHaveBeenCalledWith(expect.objectContaining({
      command: { ids: ['2'], targetId: '3', direction: 'up', mode: 'move' },
    }))
  })
})

describe('right creative tree drag feedback', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    resetDragSessionCache()
    resetDraggedState()
    jest.useFakeTimers()
    document.body.innerHTML = `<div id="creatives">${row('1', { isRoot: true })}</div>`
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
  })

  afterEach(() => {
    jest.useRealTimers()
    resetDraggedState()
    jest.clearAllMocks()
    document.body.innerHTML = ''
  })

  test('sticks to the previous edge decision across repeated dragover events', () => {
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('1'), dataTransfer))

    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 10 }))
    expect(tree('1').classList.contains('drag-over-top')).toBe(true)

    // 32 sits past the 30% boundary but inside the 12% hysteresis band, so the
    // row must stay on the top edge instead of flipping to a child drop.
    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 32 }))
    expect(tree('1').classList.contains('drag-over-top')).toBe(true)

    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 90 }))
    expect(tree('1').classList.contains('drag-over-bottom')).toBe(true)
    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 68 }))
    expect(tree('1').classList.contains('drag-over-bottom')).toBe(true)
  })

  test('schedules the hover expansion once while the pointer stays on the row', () => {
    document.body.innerHTML = `
      <div id="creatives">
        <creative-tree-row creative-id="1" level="1" has-children>
          <div class="creative-tree" id="creative-1" draggable="true"></div>
        </creative-tree-row>
        <div class="creative-children" id="creative-children-1" style="display:none"></div>
      </div>
    `
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('1'), dataTransfer))

    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    jest.advanceTimersByTime(300)
    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 51 }))
    jest.advanceTimersByTime(300)

    // The second dragover must not restart the timer, or a hovering pointer
    // would never reach the 600ms threshold.
    expect(tree('1').closest('creative-tree-row').hasAttribute('expanded')).toBe(true)
  })

  test('cancels a pending expansion when the drag ends', () => {
    document.body.innerHTML = `
      <div id="creatives">
        <creative-tree-row creative-id="1" level="1" has-children>
          <div class="creative-tree" id="creative-1" draggable="true"></div>
        </creative-tree-row>
        <div class="creative-children" id="creative-children-1" style="display:none"></div>
      </div>
    `
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    const dataTransfer = transfer()
    addGlobalListeners()
    handleDragStart(dragEvent(tree('1'), dataTransfer))
    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))

    document.dispatchEvent(new Event('dragend', { bubbles: true }))
    jest.advanceTimersByTime(600)
    removeGlobalListeners()

    expect(tree('1').closest('creative-tree-row').hasAttribute('expanded')).toBe(false)
  })
})

describe('source window synchronization', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    resetDragSessionCache()
    document.body.innerHTML = `<div id="creatives">${row('7', { isRoot: true })}</div>`
    addGlobalListeners()
  })

  afterEach(() => {
    removeGlobalListeners()
    jest.clearAllMocks()
    document.body.innerHTML = ''
  })

  // The originating window learns about the move through localStorage, so a
  // signal it can verify has to reach the tree and take the row away.
  test('removes the moved row when the originating window verifies the signal', () => {
    window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'token-under-test')
    window.sessionStorage.setItem('collavre.dragWindowId', 'this-window')
    resetDragSessionCache()

    window.dispatchEvent(Object.assign(new Event('storage'), {
      key: DROP_SIGNAL_STORAGE_KEY,
      newValue: JSON.stringify({
        creativeId: '7', sessionToken: 'token-under-test', sourceWindowId: 'this-window',
      }),
    }))

    expect(document.querySelector('creative-tree-row[creative-id="7"]')).toBeNull()
  })

  test('ignores a storage event that carries no verifiable drop signal', () => {
    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion)

    window.dispatchEvent(Object.assign(new Event('storage'), {
      key: DROP_SIGNAL_STORAGE_KEY,
      newValue: JSON.stringify({ creativeId: '7', sessionToken: 'not-our-token' }),
    }))

    window.removeEventListener('collavre:creative-drop-complete', completion)
    expect(completion).not.toHaveBeenCalled()
    expect(document.querySelector('creative-tree-row')).not.toBeNull()
  })
})
