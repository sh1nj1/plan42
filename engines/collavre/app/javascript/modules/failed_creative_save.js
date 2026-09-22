// Failed queue entries survive reloads. Restore their draft before establishing
// the editor baseline; the error state keeps a no-edit close eligible for retry.
export function recoverFailedCreative(queue, data, tree) {
  const key = `creative_${data.id}`
  if (!queue.failedItems?.some(item => item.dedupeKey === key)) return data
  const body = queue.unacknowledgedBody(key)
  const recovered = { ...data }
  for (const [field, value] of Object.entries(body)) {
    const match = field.match(/^creative\[(.+)\]$/)
    if (match) recovered[match[1]] = value
  }
  if ('creative[description]' in body) recovered.description_raw_html = body['creative[description]']
  if ('creative[content_type_input]' in body) recovered.content_type = body['creative[content_type_input]']
  tree.dataset.saveState = 'error'
  return recovered
}
