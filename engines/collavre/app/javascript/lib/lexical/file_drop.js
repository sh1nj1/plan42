import {
  $createRangeSelection, $getNodeByKey, $getRoot, $getSelection,
  $isRangeSelection, $setSelection, COMMAND_PRIORITY_HIGH, DROP_COMMAND
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
  const anchor = new UploadAnchorNode()
  $getSelection().insertNodes([anchor])
  return anchor.getKey()
}

function uploadInOrder(editor, files, anchorKey, uploadFile) {
  const results = new Array(files.length)
  let remaining = files.length
  files.forEach((file, index) => uploadFile(file, (insert, onUpdate) => {
    results[index] = { insert, onUpdate }
    if (--remaining > 0) return
    editor.update(() => {
      // The original target can disappear while the network request is pending.
      const anchor = $getNodeByKey(anchorKey)
      if (anchor?.isAttached()) {
        anchor.selectPrevious()
        anchor.remove()
      } else {
        $getRoot().selectEnd()
      }
      results.forEach(result => result.insert())
    }, { onUpdate: () => results.forEach(result => result.onUpdate()) })
  }))
}

// RichTextPlugin consumes file drops at editor priority, even when no upload
// handler is registered for its DRAG_DROP_PASTE command.
export function registerFileDrop(editor, uploadFile) {
  return editor.registerCommand(DROP_COMMAND, (event) => {
    const files = Array.from(event.dataTransfer?.files || [])
    if (files.length === 0) return false

    const selection = dropSelection(editor, event)
    event.preventDefault()
    event.stopPropagation()
    uploadInOrder(editor, files, createUploadAnchor(selection), uploadFile)
    return true
  }, COMMAND_PRIORITY_HIGH)
}
