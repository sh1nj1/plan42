import { $getSelection, $isRangeSelection, $isParagraphNode, TextNode } from "lexical"
import { $createCodeNode } from "@lexical/code"
import { markLanguageResolved } from "../editor/code_languages"

// A paragraph whose entire text is a Markdown fence opener: three backticks,
// optionally followed by a language token (e.g. ```ruby). Nothing may follow
// the language, so normal prose that merely contains backticks is untouched.
//
// A language only reaches match[1] when the whole fence lands at once (paste or
// programmatic insert); per-character typing converts on the bare ``` before a
// language can be typed, which is the intended immediate-conversion behavior.
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
 * It is a TextNode (leaf) transform on purpose: leaf transforms run for every
 * keystroke that mutates a text node, whereas an element transform on the
 * paragraph only re-runs when the paragraph's own children change. Typing the
 * third backtick just edits the existing text node, so a paragraph transform
 * never saw the completed ``` and only the space-triggered built-in fired.
 *
 * Returns the editor.registerNodeTransform teardown so callers can clean up.
 */
export function registerCodeFenceShortcut(editor) {
  return editor.registerNodeTransform(TextNode, (textNode) => {
    // The fence must be the paragraph's entire text; bail before touching the
    // parent for the common case of a text node inside anything else.
    const paragraph = textNode.getParent()
    if (!$isParagraphNode(paragraph)) return
    if (paragraph.getTopLevelElement() !== paragraph) return

    const match = paragraph.getTextContent().match(FENCE_REGEX)
    if (!match) return

    // Only convert the block the user is actively typing in — a collapsed caret
    // inside this paragraph. This keeps bulk operations (import, paste, programmatic
    // edits) that happen to produce a ``` paragraph elsewhere from being rewritten.
    const selection = $getSelection()
    if (!$isRangeSelection(selection) || !selection.isCollapsed()) return
    if (selection.anchor.getNode().getTopLevelElement() !== paragraph) return

    const language = match[1] || undefined
    const codeNode = $createCodeNode(language)
    paragraph.replace(codeNode)
    // An explicit fence language must survive the highlight transform, which
    // otherwise re-detects any block still on the "javascript" default and would
    // silently relabel a deliberate ```javascript. Mirror the import path.
    if (language) markLanguageResolved(editor, codeNode.getKey())
    codeNode.selectStart()
  })
}
