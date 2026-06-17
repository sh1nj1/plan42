import {
  $getSelection,
  $isRangeSelection,
  COMMAND_PRIORITY_LOW,
  INDENT_CONTENT_COMMAND,
  KEY_TAB_COMMAND,
  OUTDENT_CONTENT_COMMAND
} from "lexical"
import { $isListItemNode } from "@lexical/list"

/**
 * Tab / Shift+Tab indentation scoped to list items.
 *
 * Inside a list, Tab nests the current item (INDENT_CONTENT_COMMAND) and
 * Shift+Tab un-nests it (OUTDENT_CONTENT_COMMAND); @lexical/list turns those
 * indent changes into real nested <ul>/<ol> structure.
 *
 * Outside a list the command is ignored (returns false) so Tab keeps its
 * default behaviour (moving focus out of the editor) and plain paragraphs never
 * gain an indent the Markdown-canonical store can't represent cleanly.
 *
 * Returns the editor.registerCommand teardown so callers can clean up.
 */
export function registerListTabIndentation(editor) {
  return editor.registerCommand(
    KEY_TAB_COMMAND,
    (event) => {
      const selection = $getSelection()
      if (!$isRangeSelection(selection)) return false
      if (!$isSelectionWithinList(selection)) return false

      event.preventDefault()
      return editor.dispatchCommand(
        event.shiftKey ? OUTDENT_CONTENT_COMMAND : INDENT_CONTENT_COMMAND,
        undefined
      )
    },
    COMMAND_PRIORITY_LOW
  )
}

function $isSelectionWithinList(selection) {
  const anchorNode = selection.anchor.getNode()
  if ($isListItemNode(anchorNode)) return true
  return anchorNode.getParents().some($isListItemNode)
}
