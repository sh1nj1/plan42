import { creativeIdFrom } from './creative_tree_dom'

const recoveredPositions = new WeakMap()

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

// An unchanged server-rendered tree must not undo a persisted offline move.
// A subsequent explicit move in this session takes precedence over recovery.
export function queuedCreativePosition(tree) {
  const current = domPosition(tree)
  const recovered = recoveredPositions.get(tree)
  if (recovered && Object.keys(current).every(key => current[key] === recovered.baseline[key])) {
    return recovered.position
  }
  return current
}
