import { useEffect } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { registerListTabIndentation } from "../../lib/lexical/list_tab_indent"

/**
 * Enables Tab / Shift+Tab nesting for list items in the inline editor.
 * The actual command handling lives in registerListTabIndentation so it can be
 * unit-tested against a headless editor.
 */
export default function ListTabIndentPlugin() {
  const [editor] = useLexicalComposerContext()

  useEffect(() => registerListTabIndentation(editor), [editor])

  return null
}
