import { creativeIdFrom } from './creative_tree_dom'

const recoveredPositions = new WeakMap()
const acknowledgedPositions = new WeakMap()

function domPosition(tree) {
  return {
    'creative[parent_id]': tree.dataset.parentId || '',
    before_id: tree.previousElementSibling ? creativeIdFrom(tree.previousElementSibling) : '',
    after_id: tree.nextElementSibling ? creativeIdFrom(tree.nextElementSibling) : '',
  }
}

export function rememberRecoveredPosition(tree, body = {}) {
  recoveredPositions.delete(tree)
  if (!('creative[parent_id]' in body)) return
  recoveredPositions.set(tree, {
    baseline: domPosition(tree),
    position: {
      'creative[parent_id]': body['creative[parent_id]'],
      before_id: body.before_id || '',
      after_id: body.after_id || '',
    },
  })
}

// A refreshed payload does not relocate the DOM. Preserve its parent and omit
// stale sibling anchors until the user moves the row in this session.
export function rememberAcknowledgedPosition(tree, data) {
  if (!('parent_id' in data)) return
  acknowledgedPositions.set(tree, {
    baseline: domPosition(tree),
    position: { 'creative[parent_id]': data.parent_id ?? '' },
  })
}

export function withAcknowledgedParent(tree, data) {
  const position = unchangedPosition(acknowledgedPositions.get(tree), domPosition(tree))
  return position ? { ...data, parent_id: position['creative[parent_id]'] } : data
}

function unchangedPosition(saved, current) {
  if (saved && Object.keys(current).every(key => current[key] === saved.baseline[key])) return saved.position
}

// An unchanged server-rendered tree must not undo a persisted offline move.
// A subsequent explicit move in this session takes precedence over recovery.
export function queuedCreativePosition(tree) {
  const current = domPosition(tree)
  return unchangedPosition(recoveredPositions.get(tree), current) ||
    unchangedPosition(acknowledgedPositions.get(tree), current) || current
}
