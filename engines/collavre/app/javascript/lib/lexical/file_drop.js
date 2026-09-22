import {
  $addUpdateTag, $createRangeSelection, $getNodeByKey, $getRoot, $getSelection, $nodesOfType,
  $isRangeSelection, $setSelection, COMMAND_PRIORITY_HIGH, DROP_COMMAND,
  HISTORIC_TAG, HISTORY_MERGE_TAG, HISTORY_PUSH_TAG
} from "lexical"
import { UploadAnchorNode } from "./upload_anchor_node"

function dropSelection(editor, event) {
  const root = editor.getRootElement()
  const doc = root?.ownerDocument
  let range = doc?.caretRangeFromPoint?.(event.clientX, event.clientY)
  if (!range) {
    const point = doc?.caretPositionFromPoint?.(event.clientX, event.clientY)
    if (point) {
      range = doc.createRange()
      range.setStart(point.offsetNode, point.offset)
      range.collapse(true)
    }
  }
  if (range && root.contains(range.startContainer)) {
    const selection = $createRangeSelection()
    selection.applyDOMRange(range)
    return selection
  }
  const selection = $getSelection()
  return $isRangeSelection(selection) ? selection.clone() : null
}

function createUploadAnchor(selection) {
  if (selection) $setSelection(selection)
  else $getRoot().selectEnd()
  $addUpdateTag(HISTORY_MERGE_TAG)
  const anchor = new UploadAnchorNode()
  $getSelection().insertNodes([anchor])
  return anchor.getKey()
}

function commitUploads(editor, anchorKey, results) {
  let selection = null
  // Remove bookkeeping without creating an undo step. The next update records
  // only the attachment insertion, with an anchor-free state to undo to.
  editor.update(() => {
    const anchor = $getNodeByKey(anchorKey)
    if (!anchor?.isAttached()) return
    anchor.selectPrevious()
    anchor.remove()
    selection = $getSelection().clone()
  }, { tag: HISTORY_MERGE_TAG, discrete: true })
  editor.update(() => {
    // Undo or deletion of the drop target cancels insertion, never relocates it.
    if (!selection) return
    $setSelection(selection)
    results.forEach(result => result.insert())
  }, { tag: HISTORY_PUSH_TAG, onUpdate: () => results.forEach(result => result.onUpdate()) })
}

function uploadInOrder(editor, files, pending, uploadFile) {
  const results = new Array(files.length)
  let remaining = files.length
  files.forEach((file, index) => uploadFile(file, (insert, onUpdate) => {
    results[index] = { insert, onUpdate }
    if (--remaining > 0) return
    // A synchronously failed upload must not nest history updates inside DROP.
    queueMicrotask(() => {
      pending.keys.delete(pending.key)
      commitUploads(editor, pending.key, results)
    })
  }))
}

function removeFinishedAnchors(editor, pending) {
  return editor.registerUpdateListener(({ tags, editorState }) => {
    if (!tags.has(HISTORIC_TAG)) return
    const stale = editorState.read(() => $nodesOfType(UploadAnchorNode)
      .map(anchor => anchor.getKey()).filter(key => !pending.has(key)))
    if (stale.length === 0) return
    editor.update(() => {
      stale.forEach(key => $getNodeByKey(key)?.remove())
    }, { tag: HISTORIC_TAG })
  })
}

// RichTextPlugin consumes file drops at editor priority, even when no upload
// handler is registered for its DRAG_DROP_PASTE command.
export function registerFileDrop(editor, uploadFile) {
  const keys = new Set()
  const cleanup = removeFinishedAnchors(editor, keys)
  const unregister = editor.registerCommand(DROP_COMMAND, (event) => {
    const files = Array.from(event.dataTransfer?.files || [])
    if (files.length === 0) return false

    const selection = dropSelection(editor, event)
    event.preventDefault()
    event.stopPropagation()
    const key = createUploadAnchor(selection)
    keys.add(key)
    uploadInOrder(editor, files, { key, keys }, uploadFile)
    return true
  }, COMMAND_PRIORITY_HIGH)
  return () => { unregister(); cleanup() }
}
