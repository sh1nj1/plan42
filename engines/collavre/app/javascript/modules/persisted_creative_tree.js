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
  insertRow(tree, data)
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

function insertRow(tree, data) {
  if (tree.querySelector('.creative-row')) return
  const row = document.createElement('div')
  row.className = 'creative-row'
  row.style.display = 'none'
  // TODO: remove DRY, use template or copy existing dom
  row.innerHTML = `
  <div class="creative-row-start">
    <div class="creative-row-actions">
      <button type="button" class="creative-action-btn edit-inline-btn" data-creative-id="${data.id}">
        <!-- ok -->
      </button>
      <div class="creative-divider" style="width: 6px;"></div>
    </div>
    <a class="unstyled-link" href="/creatives/${data.id}">${data.description || ''}</a>
  </div>
  <div class="creative-row-end"><span class="creative-progress-incomplete">0%</span></div>`
  tree.insertBefore(row, tree.firstChild)
}
