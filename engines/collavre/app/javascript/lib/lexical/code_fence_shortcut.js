import { $getSelection, $isRangeSelection, ParagraphNode } from "lexical"
import { $createCodeNode } from "@lexical/code"

// A paragraph whose entire text is a Markdown fence opener: three backticks,
// optionally followed by a language token (e.g. ```ruby). Nothing may follow
// the language, so normal prose that merely contains backticks is untouched.
const FENCE_REGEX = /^```([\w+-]*)$/

/**
 * Turn a line that starts with a Markdown code fence into a code block as the
 * user types it — the standard rich-editor shortcut. Typing ``` (optionally
 * ```lang) on its own line replaces that paragraph with an empty code block and
 * drops the caret inside, ready for code.
 *
 * The built-in @lexical/markdown CODE transformer only fires on ``` + a trailing
 * space, so pressing Enter after the fence (what users actually do) left the
 * paragraph as plain text. This transform reacts to the fence itself.
 *
 * Returns the editor.registerNodeTransform teardown so callers can clean up.
 */
export function registerCodeFenceShortcut(editor) {
  return editor.registerNodeTransform(ParagraphNode, (node) => {
    const match = node.getTextContent().match(FENCE_REGEX)
    if (!match) return

    // Only convert the block the user is actively typing in — a collapsed caret
    // inside this paragraph. This keeps bulk operations (import, paste, programmatic
    // edits) that happen to produce a ``` paragraph elsewhere from being rewritten.
    const selection = $getSelection()
    if (!$isRangeSelection(selection) || !selection.isCollapsed()) return
    if (selection.anchor.getNode().getTopLevelElement() !== node) return

    const language = match[1] || undefined
    const codeNode = $createCodeNode(language)
    node.replace(codeNode)
    codeNode.selectStart()
  })
}
