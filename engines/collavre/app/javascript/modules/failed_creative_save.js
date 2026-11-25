import { hasRetryAttachmentIds } from './queued_creative_row'
import { rememberRecoveredPosition, withAcknowledgedParent } from './recovered_creative_position'

// Unacknowledged entries survive reloads. Restore their latest draft before
// establishing the editor baseline, including offline and in-flight saves.
export function recoverFailedCreative(queue, data, tree) {
  rememberRecoveredPosition(tree)
  const key = `creative_${data.id}`
  const failed = queue.failedItems?.some(item => item.dedupeKey === key)
  const pending = queue.queue?.some(item => item.dedupeKey === key)
  if (!failed && !pending) return withAcknowledgedParent(tree, data)
  const body = queue.unacknowledgedBody(key)
  rememberRecoveredPosition(tree, body)
  const recovered = { ...data }
  for (const [field, value] of Object.entries(body)) {
    const match = field.match(/^creative\[(.+)\]$/)
    if (match) recovered[match[1]] = value
  }
  if ('creative[description]' in body) recovered.description_raw_html = body['creative[description]']
  if ('creative[content_type_input]' in body) recovered.content_type = body['creative[content_type_input]']
  tree.dataset.saveState = failed ? 'error' : 'pending'
  return recovered
}

// Direct saves must acknowledge the recovered fields before changing type or
// performing a dependent operation. Re-register restored pending requests too,
// so their completion updates the row cache and clears its pending state.
export async function retryFailedCreativeBeforeSave(queue, creativeId, retry, tree) {
  const key = `creative_${creativeId}`
  const failed = queue.failedItems?.some(item => item.dedupeKey === key)
  const untracked = queue.queue?.some(item => item.dedupeKey === key && !item.onSuccess)
  if (failed || untracked || hasRetryAttachmentIds(tree)) await retry()
  await queue.waitFor(key)
}

// Reloaded requests have lost their completion callbacks. A no-edit close must
// enqueue a tracked snapshot; requests from this editor session already have one.
export function needsCreativeSaveRetry(queue, creativeId, tree) {
  return tree.dataset.saveState === 'error' || Boolean(queue.queue?.some(
    item => item.dedupeKey === `creative_${creativeId}` && !item.onSuccess
  ))
}
