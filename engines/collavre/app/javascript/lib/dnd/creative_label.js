export function getCreativeLabelFromDom(creativeId) {
  const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
  if (!row) return null
  const descriptionHtml = row.descriptionHtml || row.dataset?.descriptionHtml || ''
  if (!descriptionHtml) return null
  const tmp = document.createElement('div')
  tmp.innerHTML = descriptionHtml
  return (tmp.textContent || tmp.innerText || '').trim()
}
