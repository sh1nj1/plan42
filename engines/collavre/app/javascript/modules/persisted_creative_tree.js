import { treeRowElement } from './creative_row_editor_helpers'
import { forgetFailedChain } from './background_creative_create'

// Points a just-created tree, and its row component, at its new server id.
export function bindPersistedTree(tree, data, parentId, fallbackRow) {
  if (!tree) return
  tree.id = `creative-${data.id}`
  tree.dataset.id = data.id
  tree.dataset.parentId = parentId || ''
  const rowEl = treeRowElement(tree) || fallbackRow
  if (rowEl) bindRowComponent(rowEl, data.id, tree.dataset.level, parentId)
  forgetFailedChain(tree)
}

function bindRowComponent(rowEl, id, levelValue, parentId) {
  rowEl.setAttribute('creative-id', id)
  rowEl.creativeId = id
  const creativeLink = `/creatives/${id}`
  rowEl.setAttribute('link-url', creativeLink)
  rowEl.linkUrl = creativeLink
  if (levelValue) {
    rowEl.setAttribute('level', levelValue)
    rowEl.level = Number(levelValue)
  }
  if (parentId) {
    rowEl.setAttribute('parent-id', parentId)
    rowEl.parentId = parentId
    rowEl.removeAttribute('is-root')
    rowEl.isRoot = false
  } else {
    rowEl.removeAttribute('parent-id')
    rowEl.parentId = null
    rowEl.setAttribute('is-root', '')
    rowEl.isRoot = true
  }
  rowEl.canWrite = true
  rowEl.setAttribute('can-write', '')
  rowEl.requestUpdate?.()
}
