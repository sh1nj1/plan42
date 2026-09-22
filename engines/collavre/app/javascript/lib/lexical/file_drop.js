import { COMMAND_PRIORITY_HIGH, DROP_COMMAND } from "lexical"

// RichTextPlugin consumes file drops at editor priority, even when no upload
// handler is registered for its DRAG_DROP_PASTE command.
export function registerFileDrop(editor, uploadFile) {
  return editor.registerCommand(DROP_COMMAND, (event) => {
    const files = Array.from(event.dataTransfer?.files || [])
    if (files.length === 0) return false

    event.preventDefault()
    event.stopPropagation()
    files.forEach((file) => uploadFile(file))
    return true
  }, COMMAND_PRIORITY_HIGH)
}
