import { useEffect } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import {
  registerMarkdownShortcuts,
  UNORDERED_LIST,
  ORDERED_LIST,
  CODE
} from "@lexical/markdown"

/**
 * Markdown-style shortcuts for the creative inline editor:
 *
 * - "* " / "- " / "+ " at line start → unordered list
 * - "1. " (any number) at line start → ordered list
 * - "```" + space at line start → code block
 *
 * These fire on text change (not on Enter), so they don't conflict
 * with the Enter→addNew() shortcut on desktop.
 */
const CREATIVE_MARKDOWN_TRANSFORMERS = [
  UNORDERED_LIST,
  ORDERED_LIST,
  CODE
]

export default function MarkdownShortcutsPlugin() {
  const [editor] = useLexicalComposerContext()

  useEffect(() => {
    return registerMarkdownShortcuts(editor, CREATIVE_MARKDOWN_TRANSFORMERS)
  }, [editor])

  return null
}
