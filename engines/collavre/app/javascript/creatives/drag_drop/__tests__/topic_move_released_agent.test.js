/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

// The topic-move branch of handleDrop returns before touching the creative-move
// machinery, so only the modules that branch reaches need real behavior.
const sendTopicMove = jest.fn()
const alertDialog = jest.fn()
const showMissingMembersPopup = jest.fn()

jest.unstable_mockModule('../dom', () => ({
  DRAGGABLE_SELECTOR: '.tree-row',
  clearDragHighlight: jest.fn(),
  asTreeRow: jest.fn(),
  getChildrenContainer: jest.fn(),
  ensureChildrenContainer: jest.fn(),
  appendBlockToContainer: jest.fn(),
  moveBlockBefore: jest.fn(),
  moveBlockAfter: jest.fn(),
  isDescendantRow: jest.fn(),
  applyLevelDelta: jest.fn(),
  setRowParent: jest.fn(),
  setRowRootState: jest.fn(),
  setHasChildren: jest.fn(),
  setExpanded: jest.fn(),
  syncParentHasChildren: jest.fn(),
}))
jest.unstable_mockModule('../state', () => ({
  setDraggedState: jest.fn(),
  getDraggedState: jest.fn(),
  resetDraggedState: jest.fn(),
  setLastDragOverRow: jest.fn(),
  getLastDragOverRow: jest.fn(),
  hasDraggedState: jest.fn(),
}))
jest.unstable_mockModule('../operations', () => ({
  createMoveContext: jest.fn(),
  applyMove: jest.fn(),
  revertMove: jest.fn(),
}))
jest.unstable_mockModule('../../../lib/api/drag_drop', () => ({
  sendNewOrder: jest.fn(),
  sendLinkedCreative: jest.fn(),
  sendTopicMove,
}))
jest.unstable_mockModule('../indicator', () => ({
  initIndicator: jest.fn(),
  showLinkHover: jest.fn(),
  hideLinkHover: jest.fn(),
}))
jest.unstable_mockModule('../../topic_move_members_popup', () => ({
  showMissingMembersPopup,
}))
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog }))

const { handleDrop } = await import('../event_handlers')

const dropEvent = () => {
  document.body.innerHTML = '<div class="tree-row" id="creative-9"></div>'
  const target = document.getElementById('creative-9')
  return {
    target,
    preventDefault: jest.fn(),
    dataTransfer: {
      getData: (type) =>
        type === 'application/x-topic-move'
          ? JSON.stringify({ topicId: 5, sourceCreativeId: '3' })
          : '',
    },
  }
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

afterEach(() => {
  jest.clearAllMocks()
  document.body.innerHTML = ''
})

// The server releases a pin the agent cannot honor at the destination. Without
// this notice the avatar just vanishes mid-drag with no stated reason.
test('reports a primary agent released by the move', async () => {
  sendTopicMove.mockResolvedValue({
    success: true,
    missing_members: [],
    released_primary_agent: { id: 7, name: 'MoveAgent', message: 'MoveAgent was released.' },
  })

  handleDrop(dropEvent())
  await flush()

  expect(alertDialog).toHaveBeenCalledWith('MoveAgent was released.')
})

test('stays quiet when the assignment survived the move', async () => {
  sendTopicMove.mockResolvedValue({
    success: true,
    missing_members: [],
    released_primary_agent: null,
  })

  handleDrop(dropEvent())
  await flush()

  expect(alertDialog).not.toHaveBeenCalled()
})

// Both notices come off the same response, so the release must not swallow the
// missing-members prompt.
test('still offers to re-add missing members alongside the release notice', async () => {
  sendTopicMove.mockResolvedValue({
    success: true,
    target_creative_id: 9,
    target_creative_name: 'Target',
    missing_members: [{ user: { email: 'a@b.c' }, permission: 'feedback' }],
    released_primary_agent: { id: 7, name: 'MoveAgent', message: 'MoveAgent was released.' },
  })

  handleDrop(dropEvent())
  await flush()

  expect(alertDialog).toHaveBeenCalledWith('MoveAgent was released.')
  expect(showMissingMembersPopup).toHaveBeenCalled()
})
