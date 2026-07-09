import { useEffect } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import {
  registerMarkdownShortcuts,
  UNORDERED_LIST,
  ORDERED_LIST,
  CODE
} from "@lexical/markdown"
import { registerCodeFenceShortcut } from "../../lib/lexical/code_fence_shortcut"

/**
 * Markdown-style shortcuts for the creative inline editor:
 *
 * - "* " / "- " / "+ " at line start → unordered list
 * - "1. " (any number) at line start → ordered list
 * - "```" (optionally "```lang") on its own line → code block
 *
 * These fire on text change (not on Enter), so they don't conflict
 * with the Enter→addNew() shortcut on desktop. The built-in CODE transformer
 * needs "``` " (trailing space); registerCodeFenceShortcut additionally converts
 * the bare "```" fence so pressing Enter after it also opens a code block.
 */
const CREATIVE_MARKDOWN_TRANSFORMERS = [
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
