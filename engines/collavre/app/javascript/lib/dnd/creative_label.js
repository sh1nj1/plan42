export function getCreativeLabelFromDom(creativeId) {
  const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
  if (!row) return getWorkspaceLabel(creativeId)
  const descriptionHtml = row.descriptionHtml || row.dataset?.descriptionHtml || ''
  if (!descriptionHtml) return getWorkspaceLabel(creativeId)
  const tmp = document.createElement('div')
  tmp.innerHTML = descriptionHtml
  return (tmp.textContent || tmp.innerText || '').trim()
}

function getWorkspaceLabel(creativeId) {
  const link = document.querySelector(`.creative-workspace-tree-row[data-creative-id="${creativeId}"] .creative-workspace-tree-link`)
  return link ? link.textContent.trim() : null
}


export function getCreativeDropLabel(creativeId, payload) {
  const carriedLabel = payload.creativeLabels?.[creativeId]
  return getCreativeLabelFromDom(creativeId) ||
    (typeof carriedLabel === 'string' && carriedLabel) || String(creativeId)
}
