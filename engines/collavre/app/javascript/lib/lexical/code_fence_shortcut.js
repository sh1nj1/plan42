import {
  $getSelection,
  $isRangeSelection,
  $isParagraphNode,
  KEY_ENTER_COMMAND,
  COMMAND_PRIORITY_HIGH
} from "lexical"
import { $createCodeNode } from "@lexical/code"
import { markLanguageResolved } from "../editor/code_languages"

// A paragraph whose entire text is a Markdown fence opener: three backticks,
// optionally followed by a language token (e.g. ```ruby). Nothing may follow
// the language, so normal prose that merely contains backticks is untouched.
const FENCE_REGEX = /^```([\w+-]*)$/

/**
 * Open a code block when the user presses Enter on a "```" (optionally
 * "```lang") line. The built-in @lexical/markdown CODE transformer only fires on
 * "``` " + a trailing space, so Enter after the fence (what users actually do)
 * left the paragraph as plain text; this adds the Enter path.
 *
 * Enter is used deliberately rather than reacting to the fence text itself:
 * converting the moment the third backtick lands would swallow "```json" before
 * the language could be typed. Conversion must wait for the delimiter — a space
 * (handled by the built-in transformer) or Enter (handled here) — so whatever
 * language the user typed between the fence and the delimiter is captured.
 *
 * Returns the editor.registerCommand teardown so callers can clean up.
 */
export function registerCodeFenceShortcut(editor) {
  return editor.registerCommand(
    KEY_ENTER_COMMAND,
    (event) => {
      // Shift+Enter is a soft newline within a block, never a fence commit.
      if (event?.shiftKey) return false

      const selection = $getSelection()
      if (!$isRangeSelection(selection) || !selection.isCollapsed()) return false

      const paragraph = selection.anchor.getNode().getTopLevelElement()
      if (!$isParagraphNode(paragraph)) return false

      const match = paragraph.getTextContent().match(FENCE_REGEX)
      if (!match) return false

      // Swallow the newline Enter would otherwise insert; replace the fence line.
      event?.preventDefault()
      const language = match[1] || undefined
      const codeNode = $createCodeNode(language)
      paragraph.replace(codeNode)
      // An explicit fence language must survive the highlight transform, which
      // otherwise re-detects any block still on the "javascript" default and would
      // silently relabel a deliberate ```javascript. Mirror the import path.
      if (language) markLanguageResolved(editor, codeNode.getKey())
      codeNode.selectStart()
      return true
    },
    COMMAND_PRIORITY_HIGH
  )
}
