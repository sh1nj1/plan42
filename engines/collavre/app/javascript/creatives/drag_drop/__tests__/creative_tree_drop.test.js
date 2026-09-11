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
const { sendTopicMove } = await import('../../../lib/api/drag_drop')
const { showLinkHover, hideLinkHover } = await import('../indicator')
const alertDialog = jest.fn()
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog }))

const loadChildren = jest.fn()
jest.unstable_mockModule('../../../lib/api/creatives', () => ({
  loadChildren,
  default: { loadChildren },
}))

const renderCreativeTree = jest.fn()
jest.unstable_mockModule('../../tree_renderer', () => ({
  renderCreativeTree,
  appendCreativeNodes: jest.fn(),
  dispatchCreativeTreeUpdated: jest.fn(),
  applyRowProperties: jest.fn(),
}))

const {
  addGlobalListeners,
  createCreativeTreeDragDrop,
  handleDragLeave,
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

function nativeDrag(type, target, dataTransfer, { clientY = 10, shiftKey = false } = {}) {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.assign(event, { dataTransfer, clientX: 0, clientY, shiftKey })
  target.dispatchEvent(event)
  return event
}

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

  test('routes a topic through the registry into the target creative even while Shift is held', async () => {
    const registry = createCreativeTreeDragDrop()
    const dataTransfer = transfer()
    dataTransfer.setData('application/x-topic-move', JSON.stringify({ topicId: '99', sourceCreativeId: '2' }))
    sendTopicMove.mockResolvedValueOnce({})
    try {
      const over = nativeDrag('dragover', tree('1'), dataTransfer, { clientY: 0, shiftKey: true })
      expect(over.defaultPrevented).toBe(true)
      expect(dataTransfer.dropEffect).toBe('move')
      expect(hideLinkHover).toHaveBeenCalled()
      nativeDrag('drop', tree('1'), dataTransfer, { clientY: 0, shiftKey: true })
      await flush()
      expect(sendTopicMove).toHaveBeenCalledWith({ topicId: '99', sourceCreativeId: '2', targetCreativeId: '1' })
      expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
    } finally {
      registry.destroy()
    }
  })

  test('rejects disabled rows through the registry without claiming the browser drop', () => {
    const registry = createCreativeTreeDragDrop()
    const dataTransfer = transfer()
    tree('1').draggable = false
    dataTransfer.setData('application/x-topic-id', '99')
    try {
      expect(nativeDrag('dragover', tree('1'), dataTransfer).defaultPrevented).toBe(false)
      expect(nativeDrag('drop', tree('1'), dataTransfer).defaultPrevented).toBe(false)
      expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
    } finally {
      registry.destroy()
    }
  })

  test('ignores a browser drag event with no transfer or active creative session', () => {
    const registry = createCreativeTreeDragDrop()
    try {
      expect(nativeDrag('dragover', tree('1'), null).defaultPrevented).toBe(false)
      expect(nativeDrag('drop', tree('1'), null).defaultPrevented).toBe(false)
      expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
    } finally {
      registry.destroy()
    }
  })

  test('updates the registered creative effect when Shift changes over the same target', () => {
    const registry = createCreativeTreeDragDrop()
    const dataTransfer = transfer()
    try {
      nativeDrag('dragstart', tree('2'), dataTransfer)
      nativeDrag('dragover', tree('1'), dataTransfer, { shiftKey: true })
      expect(dataTransfer.dropEffect).toBe('copy')
      expect(showLinkHover).toHaveBeenCalled()
      nativeDrag('dragover', tree('1'), dataTransfer)
      expect(dataTransfer.dropEffect).toBe('move')
    } finally {
      registry.destroy()
    }
  })

  test('publishes an envelope the shared reader accepts', () => {
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('1'), dataTransfer))

    // A shift-drag links, and a link target answers 'copy'. Advertising 'move'
    // alone makes the browser negotiate that pair down to no drag operation.
    expect(dataTransfer.effectAllowed).toBe('copyMove')
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

  // The workspace tree answers a shift-drag with dropEffect 'copy'. Reporting
  // 'move' here would leave the two trees advertising incompatible effects.
  test('answers a shift-drag with the copy effect', () => {
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('1'), dataTransfer))

    handleDragOver(dragEvent(tree('2'), dataTransfer, { shiftKey: true }))
    expect(dataTransfer.dropEffect).toBe('copy')

    handleDragOver(dragEvent(tree('2'), dataTransfer))
    expect(dataTransfer.dropEffect).toBe('move')
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

  test('the registry preserves same-window dragging when storage blocks MIME writes', async () => {
    const getItem = jest.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('blocked') })
    const setItem = jest.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked') })
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    const registry = createCreativeTreeDragDrop()
    try {
      const dataTransfer = transfer()
      nativeDrag('dragstart', tree('2'), dataTransfer)
      expect(dataTransfer.types).toEqual([])
      expect(nativeDrag('dragover', tree('1'), dataTransfer).defaultPrevented).toBe(true)
      nativeDrag('drop', tree('1'), dataTransfer)
      await flush()
      expect(runMoveWithDomRecovery).toHaveBeenCalledWith(expect.objectContaining({
        command: { ids: ['2'], targetId: '1', direction: 'up', mode: 'move' },
        moveContext: { context: true },
      }))
    } finally {
      registry.destroy()
      getItem.mockRestore()
      setItem.mockRestore()
      consoleError.mockRestore()
    }
  })

  test.each(['invalid token', 'malformed JSON', 'unrelated MIME'])(
    'the registry never replaces %s with local drag state', async kind => {
      const registry = createCreativeTreeDragDrop()
      const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
      try {
        let dataTransfer = transfer()
        nativeDrag('dragstart', tree('2'), dataTransfer)
        if (kind === 'unrelated MIME') {
          dataTransfer = transfer()
          dataTransfer.setData('text/plain', 'untrusted')
        } else {
          const payload = JSON.parse(dataTransfer.getData('application/x-collavre-creative'))
          dataTransfer.setData('application/x-collavre-creative', kind === 'malformed JSON'
            ? 'not JSON' : JSON.stringify({ ...payload, token: 'invalid' }))
        }
        nativeDrag('dragover', tree('1'), dataTransfer)
        nativeDrag('drop', tree('1'), dataTransfer)
        await flush()
        expect(runMoveWithDomRecovery).not.toHaveBeenCalled()
      } finally {
        registry.destroy()
        consoleError.mockRestore()
      }
    }
  )

  test('a numeric legacy creative id keeps same-window DOM recovery', async () => {
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('2'), dataTransfer))
    const payload = JSON.parse(dataTransfer.getData('application/x-collavre-creative'))
    dataTransfer.setData('application/x-collavre-creative', JSON.stringify({ ...payload, creativeId: 2 }))
    await handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 10 }))
    expect(createMoveContext).toHaveBeenCalled()
    expect(runMoveWithDomRecovery).toHaveBeenCalledWith(expect.objectContaining({
      command: { ids: ['2'], targetId: '1', direction: 'up', mode: 'move' },
      moveContext: { context: true },
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

  test('surfaces a partial move instead of reporting a clean success', async () => {
    runMoveWithDomRecovery.mockResolvedValue({
      status: 'partial',
      succeededIds: ['1'],
      failedIds: ['2'],
      failures: [{
        id: '2',
        reason: 'permission_denied',
        message: 'HTTP 403: Forbidden',
        serverMessage: 'Not allowed',
      }],
    })
    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion, { once: true })
    const dataTransfer = transfer()

    handleDragStart(dragEvent(tree('2'), dataTransfer))
    handleDrop(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await flush()

    expect(alertDialog).toHaveBeenCalledWith('Not allowed')
    // The rows that did move still need both trees to refresh.
    expect(completion).toHaveBeenCalled()
  })

  test('the registered drop path uses the translated partial failure message', async () => {
    runMoveWithDomRecovery.mockResolvedValue({
      status: 'partial', succeededIds: ['2'], failedIds: ['9'], failures: [],
    })
    const registry = createCreativeTreeDragDrop({ partialFailureMessage: 'Retry missing links only' })
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('2'), dataTransfer))
    const drop = new Event('drop', { bubbles: true, cancelable: true })
    Object.assign(drop, { dataTransfer, clientX: 0, clientY: 50, shiftKey: true })
    tree('1').dispatchEvent(drop)
    await flush()
    expect(alertDialog).toHaveBeenCalledWith('Retry missing links only')
    registry.destroy()
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

  test.each([
    [['8', '9'], '9', 'creative-9'],
    [['8'], '8', null],
    [['9'], '9', 'creative-9'],
  ])('pairs the source tree with its successful dragged row for %j', async (succeededIds, creativeId, treeId) => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'token-under-test')
    resetDragSessionCache()
    const setItem = jest.spyOn(Storage.prototype, 'setItem')
    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion, { once: true })
    runMoveWithDomRecovery.mockResolvedValue({
      status: succeededIds.length === 2 ? 'success' : 'partial', ok: succeededIds.length === 2,
      succeededIds, failedIds: ['8', '9'].filter(id => !succeededIds.includes(id)), failures: [],
    })
    const dataTransfer = transfer()
    dataTransfer.setData('application/x-collavre-creative', JSON.stringify({
      creativeId: '9', treeId: 'creative-9', selectedCreativeIds: ['8', '9'],
      token: 'token-under-test', sourceWindowId: 'other-window',
    }))

    await handleDrop(dragEvent(tree('1'), dataTransfer))

    expect(completion).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeId, treeId, creativeIds: succeededIds }),
    }))
    const signal = setItem.mock.calls.find(([key]) => key === DROP_SIGNAL_STORAGE_KEY)
    expect(JSON.parse(signal[1])).toEqual(expect.objectContaining({ creativeId, treeId, creativeIds: succeededIds }))
    setItem.mockRestore()
    consoleError.mockRestore()
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

  // A collapsed branch renders empty with data-loaded="false", so revealing the
  // container alone would advertise an expansion with nothing to drop onto.
  test('fills a lazily loaded branch before revealing it', async () => {
    document.body.innerHTML = `
      <div id="creatives">
        <creative-tree-row creative-id="1" level="1" has-children>
          <div class="creative-tree" id="creative-1" draggable="true"></div>
        </creative-tree-row>
        <div class="creative-children" id="creative-children-1" style="display:none"
             data-loaded="false" data-load-url="/creatives/1/children.json"></div>
      </div>
    `
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    loadChildren.mockResolvedValue({ creatives: [{ id: 2 }] })
    const container = document.getElementById('creative-children-1')
    renderCreativeTree.mockImplementationOnce((target) => {
      target.innerHTML = row('2', { parentId: '1', level: 2 })
    })
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('1'), dataTransfer))

    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await jest.advanceTimersByTimeAsync(600)

    expect(loadChildren).toHaveBeenCalledWith('/creatives/1/children.json')
    expect(renderCreativeTree).toHaveBeenCalledWith(container, [{ id: 2 }])
    expect(container.dataset.loaded).toBe('true')
    expect(tree('1').closest('creative-tree-row').hasAttribute('has-children')).toBe(true)
    expect(tree('1').closest('creative-tree-row').hasAttribute('expanded')).toBe(true)
  })

  test('does not apply an in-flight hover response after the drop starts', async () => {
    let resolveChildren
    document.body.innerHTML = `
<div id="creatives">
${row('1', { isRoot: true })}
<creative-tree-row creative-id="2" level="1" has-children>
<div class="creative-tree" id="creative-2" draggable="true"></div>
</creative-tree-row>
<div class="creative-children" id="creative-children-2" style="display:none"
data-loaded="false" data-load-url="/creatives/2/children.json"></div>
</div>
`
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    tree('2').getBoundingClientRect = () => ({ top: 0, height: 100 })
    loadChildren.mockImplementation(() => new Promise((resolve) => { resolveChildren = resolve }))
    runMoveWithDomRecovery.mockResolvedValue({ status: 'success' })
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('1'), dataTransfer))
    handleDragOver(dragEvent(tree('2'), dataTransfer, { clientY: 50 }))
    await jest.advanceTimersByTimeAsync(600)

    handleDrop(dragEvent(tree('2'), dataTransfer, { clientY: 50 }))
    resolveChildren({ creatives: [{ id: 3 }] })
    await Promise.resolve()

    expect(runMoveWithDomRecovery).toHaveBeenCalled()
    expect(renderCreativeTree).not.toHaveBeenCalled()
    expect(document.getElementById('creative-children-2').dataset.loaded).toBe('false')
  })

  test('does not apply an in-flight hover response after leaving the target', async () => {
    let resolveChildren
    document.body.innerHTML = `
<creative-tree-row creative-id="1" level="1" has-children>
<div class="creative-tree" id="creative-1" draggable="true"></div>
</creative-tree-row>
<div class="creative-children" id="creative-children-1" style="display:none"
data-loaded="false" data-load-url="/creatives/1/children.json"></div>
`
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    loadChildren.mockImplementation(() => new Promise((resolve) => { resolveChildren = resolve }))
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('1'), dataTransfer))
    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await jest.advanceTimersByTimeAsync(600)

    handleDragLeave(dragEvent(tree('1'), dataTransfer))
    resolveChildren({ creatives: [{ id: 2 }] })
    await Promise.resolve()

    expect(renderCreativeTree).not.toHaveBeenCalled()
    expect(document.getElementById('creative-children-1').dataset.loaded).toBe('false')
  })

  test('allows dragleave cleanup when no hover expansion is pending', () => {
    const dataTransfer = transfer()

    expect(() => handleDragLeave(dragEvent(tree('1'), dataTransfer))).not.toThrow()
  })

  test('settles a branch the server reports as empty', async () => {
    document.body.innerHTML = `
      <div id="creatives">
        <creative-tree-row creative-id="1" level="1" has-children>
          <div class="creative-tree" id="creative-1" draggable="true"></div>
        </creative-tree-row>
        <div class="creative-children" id="creative-children-1" style="display:none"
             data-loaded="false" data-load-url="/creatives/1/children.json"></div>
      </div>
    `
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    loadChildren.mockResolvedValue({})
    const container = document.getElementById('creative-children-1')
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('1'), dataTransfer))

    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await jest.advanceTimersByTimeAsync(600)

    expect(renderCreativeTree).toHaveBeenCalledWith(container, [])
    expect(container.dataset.loaded).toBe('true')
    expect(tree('1').closest('creative-tree-row').hasAttribute('has-children')).toBe(false)
    expect(tree('1').closest('creative-tree-row').hasAttribute('expanded')).toBe(false)
    expect(container.style.display).toBe('none')
  })

  test('leaves the branch collapsed when its children cannot be loaded', async () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    document.body.innerHTML = `
      <div id="creatives">
        <creative-tree-row creative-id="1" level="1" has-children>
          <div class="creative-tree" id="creative-1" draggable="true"></div>
        </creative-tree-row>
        <div class="creative-children" id="creative-children-1" style="display:none"
             data-loaded="false" data-load-url="/creatives/1/children.json"></div>
      </div>
    `
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    loadChildren.mockRejectedValue(new Error('offline'))
    const dataTransfer = transfer()
    handleDragStart(dragEvent(tree('1'), dataTransfer))

    handleDragOver(dragEvent(tree('1'), dataTransfer, { clientY: 50 }))
    await jest.advanceTimersByTimeAsync(600)

    expect(tree('1').closest('creative-tree-row').hasAttribute('expanded')).toBe(false)
    expect(consoleError).toHaveBeenCalledWith(
      'Failed to load children for branch expansion',
      expect.objectContaining({ message: 'offline' })
    )
    consoleError.mockRestore()
  })

  test('retries a failed hover load while the registry preview stays active', async () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    document.body.innerHTML = `
      <div id="creatives">
        <creative-tree-row creative-id="1" level="1" has-children>
          <div class="creative-tree" id="creative-1" draggable="true"></div>
        </creative-tree-row>
        <div class="creative-children" id="creative-children-1" style="display:none"
             data-loaded="false" data-load-url="/creatives/1/children.json"></div>
      </div>
    `
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    loadChildren
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce({ creatives: [{ id: 2 }] })
    renderCreativeTree.mockImplementationOnce((target) => {
      target.innerHTML = row('2', { parentId: '1', level: 2 })
    })
    const dataTransfer = transfer()
    const registry = createCreativeTreeDragDrop()

    try {
      nativeDrag('dragstart', tree('1'), dataTransfer)
      nativeDrag('dragover', tree('1'), dataTransfer, { clientY: 50 })
      await jest.advanceTimersByTimeAsync(600)

      nativeDrag('dragover', tree('1'), dataTransfer, { clientY: 50 })
      await jest.advanceTimersByTimeAsync(600)

      expect(loadChildren).toHaveBeenCalledTimes(2)
      expect(tree('1').closest('creative-tree-row').hasAttribute('expanded')).toBe(true)
    } finally {
      registry.destroy()
      consoleError.mockRestore()
    }
  })

  test('retries when the pointer re-enters during an obsolete hover load', async () => {
    let resolveFirstLoad
    document.body.innerHTML = `
      <div id="creatives">
        <creative-tree-row creative-id="1" level="1" has-children>
          <div class="creative-tree" id="creative-1" draggable="true"></div>
        </creative-tree-row>
        <div class="creative-children" id="creative-children-1" style="display:none"
             data-loaded="false" data-load-url="/creatives/1/children.json"></div>
      </div>
    `
    tree('1').getBoundingClientRect = () => ({ top: 0, height: 100 })
    loadChildren
      .mockImplementationOnce(() => new Promise((resolve) => { resolveFirstLoad = resolve }))
      .mockResolvedValueOnce({ creatives: [{ id: 2 }] })
    renderCreativeTree.mockImplementationOnce((target) => {
      target.innerHTML = row('2', { parentId: '1', level: 2 })
    })
    const dataTransfer = transfer()
    const registry = createCreativeTreeDragDrop()

    try {
      nativeDrag('dragstart', tree('1'), dataTransfer)
      nativeDrag('dragover', tree('1'), dataTransfer, { clientY: 50 })
      await jest.advanceTimersByTimeAsync(600)

      nativeDrag('dragleave', tree('1'), dataTransfer)
      nativeDrag('dragover', tree('1'), dataTransfer, { clientY: 50 })
      resolveFirstLoad({ creatives: [{ id: 2 }] })
      await jest.advanceTimersByTimeAsync(0)
      expect(renderCreativeTree).not.toHaveBeenCalled()

      await jest.advanceTimersByTimeAsync(600)

      expect(loadChildren).toHaveBeenCalledTimes(2)
      expect(tree('1').closest('creative-tree-row').hasAttribute('expanded')).toBe(true)
    } finally {
      registry.destroy()
    }
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
