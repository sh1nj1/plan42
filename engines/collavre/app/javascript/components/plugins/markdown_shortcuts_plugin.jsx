import { useEffect } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import {
  registerMarkdownShortcuts,
  UNORDERED_LIST,
  ORDERED_LIST,
  CODE,
  HEADING
} from "@lexical/markdown"
import { registerCodeFenceShortcut } from "../../lib/lexical/code_fence_shortcut"

/**
 * Markdown-style shortcuts for the creative inline editor:
 *
 * - "# " / "## " / "### " at line start → heading
 * - "* " / "- " / "+ " at line start → unordered list
 * - "1. " (any number) at line start → ordered list
 * - "```" (optionally "```lang") on its own line → code block
 *
 * The list transformers fire on text change. The built-in CODE transformer
 * needs "``` " (trailing space); registerCodeFenceShortcut adds the Enter path,
 * converting a "```" (or "```lang") line to a code block when Enter is pressed —
 * so the language can be typed before the fence commits.
 */
export const CREATIVE_MARKDOWN_TRANSFORMERS = [
  { ...HEADING, regExp: /^(#{1,3})\s/ },
  UNORDERED_LIST,
  ORDERED_LIST,
  CODE
]

export default function MarkdownShortcutsPlugin() {
  const [editor] = useLexicalComposerContext()

  useEffect(() => {
    const unregisterShortcuts = registerMarkdownShortcuts(
      editor,
      CREATIVE_MARKDOWN_TRANSFORMERS
    )
    const unregisterFence = registerCodeFenceShortcut(editor)
    return () => {
      unregisterShortcuts()
      unregisterFence()
    }
  }, [editor])

  return null
}
