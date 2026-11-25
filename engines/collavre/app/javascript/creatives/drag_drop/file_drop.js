import { createDragDropRegistry } from '../../lib/dnd/registry'
import { getDragKind } from '../../lib/dnd/envelope'
import { getVerticalDropPosition } from '../../lib/dnd/hit_test'
import { isDragLocked } from '../../components/creative_tree_row_document_view'
import { invalidateCreativeTree } from '../../lib/creative_tree_invalidation'
import csrfFetch from '../../lib/api/csrf_fetch'
import { alertDialog } from '../../lib/utils/dialog'
import { DRAGGABLE_SELECTOR, asTreeRow, clearDragHighlight } from './dom'

export function fileDragKind(transfer) {
  if (getDragKind(transfer)) return null
  return Array.from(transfer?.types || []).includes('Files') ? 'files' : null
}

function readFiles(transfer) {
  const files = Array.from(transfer?.files || [])
  return files.length ? { kind: 'files', payload: { files } } : null
}

function previewFiles({ el, hit }) {
  clearDragHighlight(el)
  const position = { up: 'top', down: 'bottom', child: 'child' }[hit]
  el.classList.add('drag-over', `drag-over-${position}`)
  if (hit === 'child') el.classList.add('child-drop-indicator-active')
  return () => clearDragHighlight(el)
}

export async function uploadDroppedFiles({ el, hit, payload }, failureMessage) {
  const id = asTreeRow(el)?.getAttribute('creative-id')
  if (!id) return
  const body = new FormData()
  body.append('direction', hit)
  payload.files.forEach(file => body.append('files[]', file))
  try {
    const response = await csrfFetch(`/creatives/${id}/file_drops`, {
      method: 'POST', headers: { Accept: 'application/json' }, body,
    })
    if (!response.ok || response.redirected) throw new Error('File drop failed')
    await response.json()
    invalidateCreativeTree()
  } catch (error) {
    console.error('File drop failed', error)
    await alertDialog(failureMessage)
  }
}

export function createCreativeFileDrop({ failureMessage }) {
  const registry = createDragDropRegistry({ getKind: fileDragKind, readData: readFiles })
  registry.registerDropZone({
    selector: DRAGGABLE_SELECTOR,
    accepts: ['files'],
    hitTest: ({ el, event, previousHit }) => isDragLocked(el) ? null : getVerticalDropPosition({
      clientY: event.clientY, rect: el.getBoundingClientRect(), previousPosition: previousHit,
    }),
    preview: previewFiles,
    dropEffect: () => 'copy',
    onDrop: data => uploadDroppedFiles(data, failureMessage),
  })
  return registry
}
